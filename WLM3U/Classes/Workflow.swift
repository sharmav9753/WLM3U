//
//  Workflow.swift
//  WLM3U
//
//  Created by Willie on 2019/7/7.
//  Copyright © 2019 Willie. All rights reserved.
//

import Foundation
import Alamofire

protocol WorkflowDelegate: AnyObject {
    func workflow(didFinish workflow: Workflow)
}

/// A class responsible for a single m3u task.
open class Workflow {
    
    /// Raw url.
    let url: URL
    
    /// An delegate that is usually the default `Manager`.
    weak var delegate: WorkflowDelegate?
    
    /// A model class for saving data parsed from a m3u file.
    var model: Model = Model()
    
    // Global
    
    private weak var fileManager = FileManager.default
    private var waitingFiles = [String]()
    private let workSpace: URL
    private var workflowDir: URL?
    private var tsDir: URL?
    
    private let operationQueue: OperationQueue  = {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .utility
        return operationQueue
    }()
    
    private let dispatchQueue = DispatchQueue(label: "com.willie.WLM3UManager")
    
    // Download
    
    private var downloadTimer: Timer?
    private var preCompletedCount: Int = 0
    private var currentRequest: DownloadRequest?
    private var progressDic = [String: Progress]()
    private var downloadProgress: DownloadProgress?
    private var downloadCompletion: DownloadCompletion?
    
    // Combine
    
    private var combineCompletion: CombineCompletion?
    
    init(url: URL, workSpace: URL) {
        self.url = url
        self.workSpace = workSpace
    }
    
    /// Cancels all tasks holding by the `Workflow`.
    public func cancel() {
        destroyTimer()
        currentRequest?.cancel()
        progressDic.removeAll()
        waitingFiles.removeAll()
        currentRequest = nil
        downloadProgress = nil
        downloadCompletion = nil
        combineCompletion = nil
    }
}

// MARK: - Attach

extension Workflow {
    
    /// Creates a `Workflow` to retrieve the contents of the specified `url` and `completion`.
    ///
    /// - Parameters:
    ///   - url:        A URL of m3u file.
    ///   - completion: The attach task completion callback.
    /// - Returns: A `Workflow` instance.
    @discardableResult
    func attach(completion: AttachCompletion?) -> Self {
        operationQueue.isSuspended = true
        
        // e.g. http://qq.com/123/hls/FromSoftware.m3u
        
        let m3uName: String = url.deletingPathExtension().lastPathComponent // FromSoftware
        workflowDir = workSpace.appendingPathComponent(m3uName) // ../workSpace/FromSoftware
        let cacheURL = workflowDir!.appendingPathComponent("m3uObj")
        
        if fileManager!.fileExists(atPath: cacheURL.path) {
            
            do {
                let data = try Data(contentsOf: cacheURL)
                model = try JSONDecoder().decode(Model.self, from: data)
            } catch {
                handleCompletion(of: completion, result: .failure(.handleCacheFailed(error)))
                return self
            }
            
            let tsDirName: String = model.tsArr?.first?.components(separatedBy: "/").first ?? "ts"
            tsDir = workflowDir!.appendingPathComponent(tsDirName) // ../workSpace/FromSoftware/ts
            
            handleCompletion(of: completion, result: .success(model))
            return self
        }
        
        model.url = url
        
        let uri: URL = url.deletingLastPathComponent() // http://qq.com/123/hls/
        model.uri = uri
        model.name = m3uName
        
        var isDir: ObjCBool = false
        let exists: Bool = fileManager!.fileExists(atPath: workflowDir!.path, isDirectory: &isDir)
        if !isDir.boolValue || !exists {
            do {
                try fileManager!.createDirectory(at: workflowDir!,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
                try url.absoluteString.write(to: workflowDir!.appendingPathComponent("URL"),
                                             atomically: true,
                                             encoding: .utf8)
            } catch {
                operationQueue.cancelAllOperations()
                handleCompletion(of: completion, result: .failure(.handleCacheFailed(error)))
                return self
            }
        }
        
        // Download m3u file ...
        Alamofire.download(URLRequest(url: url),
                           to: { (_, _) -> (destinationURL: URL, options: DownloadRequest.DownloadOptions) in
                            return (self.workflowDir!.appendingPathComponent("m3u"), [.removePreviousFile])
        })
            .responseData { (response) in
                
                if let error = response.error {
                    self.handleCompletion(of: completion, result: .failure(.downloadFailed(error)))
                    return
                }
                
                guard let destinationURL = response.destinationURL else {
                    self.operationQueue.cancelAllOperations()
                    self.handleCompletion(of: completion, result: .failure(.downloadFailed(nil)))
                    return
                }
                
                self.m3uDownloadDidFinished(at: destinationURL, completion: completion)
        }
        
        return self
    }
    
    private func m3uDownloadDidFinished(at url: URL, completion: AttachCompletion?) {
        
        guard let workflowDir = workflowDir else {
            handleCompletion(of: completion, result: .failure(.logicError))
            return
        }
        
        do {
            try parseM3u(file: url)
            let data = try JSONEncoder().encode(model)
            let cacheURL = workflowDir.appendingPathComponent("m3uObj") // ../workSpace/FromSoftware/m3uObj
            if fileManager!.fileExists(atPath: cacheURL.path) {
                try fileManager!.removeItem(at: cacheURL)
            }
            try data.write(to: cacheURL)
        } catch {
            handleCompletion(of: completion, result: .failure(.handleCacheFailed(error)))
            return
        }
        
        let tsDirName: String = model.tsArr?.first?.components(separatedBy: "/").first ?? "ts"
        tsDir = workflowDir.appendingPathComponent(tsDirName) // ../workSpace/FromSoftware/ts
        
        do {
            try fileManager!.removeItem(at: workflowDir.appendingPathComponent("m3u"))
            try fileManager!.createDirectory(at: tsDir!,
                                             withIntermediateDirectories: true,
                                             attributes: nil)
        } catch {
            handleCompletion(of: completion, result: .failure(.handleCacheFailed(error)))
            return
        }
        
        handleCompletion(of: completion, result: .success(model))
    }
    
    private func parseM3u(file: URL) throws {
        let m3uStr = try String(contentsOf: file)
        let arr = m3uStr.components(separatedBy: "\n")
        var tsArr = [String]()
        var totalSize: Int = 0
        for str in arr {
            if str.hasPrefix("ts/") {
                tsArr.append(str)
            } else if str.hasPrefix("#EXTINF:") {
                if let sizeStr = str.components(separatedBy: "segment_size=").last, let size = Int(sizeStr) {
                    totalSize += size
                }
            }
        }
        model.tsArr = tsArr
        model.totalSize = totalSize
        if model.tsArr?.count == 0 || model.totalSize == 0 {
            throw WLError.m3uFileContentInvalid
        }
    }
}

// MARK: - Download

extension Workflow {
    
    /// Begin a download task.
    ///
    /// - Parameters:
    ///   - progress:   Download progress callback, called once per second.
    ///   - completion: Download completion callback.
    /// - Returns: A reference to self.
    @discardableResult
    public func download(progress: DownloadProgress? = nil, completion: DownloadCompletion? = nil) -> Self {
        downloadProgress = progress
        downloadCompletion = completion
        operationQueue.addOperation {
            self.operationQueue.isSuspended = true
            guard let tsArr = self.model.tsArr else {
                self.handleCompletion(of: completion, result: .failure(.logicError))
                return
            }
            self.waitingFiles = tsArr
            self.downloadNextFile()
            self.createTimer()
        }
        return self
    }
    
    private func downloadNextFile() {
        
        guard let uri = model.uri else {
            handleCompletion(of: downloadCompletion, result: .failure(.logicError))
            return
        }
        
        let tsStr = waitingFiles.removeFirst()
        let fullURL: URL = uri.appendingPathComponent(tsStr) // http://qq.com/123/hls/ts/200.ts
        let fileName: String = tsStr.components(separatedBy: "/").last! // 200.ts
        let fileLocalURL = self.tsDir!.appendingPathComponent(fileName)
        
        // Check if file is exsist.
        
        if fileManager!.fileExists(atPath: fileLocalURL.path) {
            
            do {
                let size = try fileManager!.attributesOfItem(atPath: fileLocalURL.path)[FileAttributeKey.size] as! Int64
                let progress = Progress(totalUnitCount: size)
                progress.completedUnitCount = size
                self.progressDic[tsStr] = progress
                
                if self.waitingFiles.count > 0 {
                    self.downloadNextFile()
                } else {
                    self.allDownloadsDidFinished()
                }
                
                return
                
            } catch {
                handleCompletion(of: downloadCompletion, result: .failure(.handleCacheFailed(error)))
                return
            }
        }
        
        let req = URLRequest(url: fullURL)
        let destination: DownloadRequest.DownloadFileDestination = {(_, _) -> (destinationURL: URL, options: DownloadRequest.DownloadOptions) in
            return (fileLocalURL, [.removePreviousFile])
        }
        
        let request = Alamofire
            .download(req, to: destination)
            .downloadProgress { (progress) in
                self.progressDic[tsStr] = progress
        }
        
        request.response(completionHandler: { (response) in
            
            if let error = response.error as NSError? {
                if error.code == -999 { return } // cancelled
                self.currentRequest = nil
                self.waitingFiles.insert(tsStr, at: 0)
                self.downloadNextFile()
                return
            }
            
            if self.waitingFiles.count > 0 {
                self.downloadNextFile()
            } else {
                self.allDownloadsDidFinished()
            }
        })
        
        currentRequest = request
    }
    
    private func createTimer() {
        DispatchQueue.main.async {
            self.downloadTimer = Timer.scheduledTimer(timeInterval: 1,
                                                      target: self,
                                                      selector: #selector(self.timerFire),
                                                      userInfo: nil,
                                                      repeats: true)
            RunLoop.current.add(self.downloadTimer!, forMode: RunLoop.Mode.common)
        }
    }
    
    private func destroyTimer() {
        downloadTimer?.invalidate()
        downloadTimer = nil
    }
    
    @objc private func timerFire() {
        
        guard let totalSize = model.totalSize else {
            handleCompletion(of: downloadCompletion, result: .failure(.logicError))
            return
        }
        
        let progress = Progress(totalUnitCount: Int64(totalSize))
        for pro in progressDic.values {
            progress.completedUnitCount += pro.completedUnitCount
        }
        
        let completedCount = Int(progress.completedUnitCount) - self.preCompletedCount
        preCompletedCount = Int(progress.completedUnitCount)
        downloadProgress?(progress, completedCount)
    }
    
    private func allDownloadsDidFinished() {
        timerFire()
        destroyTimer()
        handleCompletion(of: downloadCompletion, result: .success(self.tsDir!))
    }
}

// MARK: - Combine

extension Workflow {
    
    /// Begin a combine task.
    ///
    /// - Parameters:
    ///   - completion: combine completion callback.
    /// - Returns: A reference to self.
    @discardableResult
    public func combine(completion: CombineCompletion? = nil) -> Self {
        combineCompletion = completion
        operationQueue.addOperation {
            self.doCombine()
        }
        return self
    }
    
    private func doCombine() {
        
        guard
            let name = model.name,
            let tsArr = model.tsArr,
            let tsDir = tsDir,
            let workflowDir = workflowDir else {
                handleCompletion(of: combineCompletion, result: .failure(WLError.logicError))
                return
        }
        
        let combineFilePath = workflowDir.appendingPathComponent(name).appendingPathExtension("ts")
        fileManager!.createFile(atPath: combineFilePath.path, contents: nil, attributes: nil)
        let tsFilePaths = tsArr.map { tsDir.path + "/" + $0.components(separatedBy: "/").last! }
        
        dispatchQueue.async {
            
            let fileHandle = FileHandle(forUpdatingAtPath: combineFilePath.path)
            for tsFilePath in tsFilePaths {
                let data = try! Data(contentsOf: URL(fileURLWithPath: tsFilePath))
                fileHandle?.write(data)
            }
            fileHandle?.closeFile()
            
            do {
                try self.fileManager!.removeItem(at: self.tsDir!)
                let cacheURL = self.workflowDir!.appendingPathComponent("m3uObj")
                try self.fileManager!.removeItem(at: cacheURL)
            } catch {
                DispatchQueue.main.async {
                    self.handleCompletion(of: self.combineCompletion, result: .failure(.handleCacheFailed(error)))
                }
            }
            
            DispatchQueue.main.async {
                self.handleCompletion(of: self.combineCompletion, result: .success(combineFilePath))
            }
        }
    }
}

// MARK: - Helper

private extension Workflow {
    
    func handleCompletion<T>(of completion: ((Result<T>) -> ())?, result: Result<T>) {
        
        switch result {
        case .failure(_):
            operationQueue.cancelAllOperations()
            destroyTimer()
        case .success(_):
            operationQueue.isSuspended = false
        }
        completion?(result)
        
        if operationQueue.operationCount == 0 {
            delegate?.workflow(didFinish: self)
        }
    }
}
