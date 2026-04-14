//
//  CloudCoreCacheable.swift
//  CloudCore
//
//  Created by deeje cooley on 4/16/22.
//

import Foundation
import CoreData

public enum CacheState: String {
    case local
    case upload         // -> uploading -> cached
    case uploading
    
    case remote
    case download       // -> downloading -> cached
    case downloading
    
    case cached
    
    case unload         // -> remote
    
    case cancel         // -> uploading -> local OR downloading -> remote
}

public enum RemoteStatus: String {
    case pending
    case available
}

public protocol CloudCoreCacheable: CloudCoreType {
    
        // fully masked
    var cacheStateRaw: String? { get set }
    var operationID: String? { get set }
    var uploadProgress: Double { get set }
    var downloadProgress: Double { get set }
    var lastErrorMessage: String? { get set }
    
    var pinned: Bool { get set }
    var lastUsed: Date? { get set }
    
        // sync'ed
    var remoteStatusRaw: String? { get set }
    var suffix: String? { get set }
    
    var size: Int64 { get set }
    
}

public extension CloudCoreCacheable {
    
    var assetFieldName: String {
        return "assetData"
    }
    
    var cacheState: CacheState {
        get {
            return cacheStateRaw == nil ? .remote : CacheState(rawValue: cacheStateRaw!)!
        }
        set {
            cacheStateRaw = newValue.rawValue
        }
    }
    
    var remoteStatus: RemoteStatus {
        get {
            return remoteStatusRaw == nil ? .pending : RemoteStatus(rawValue: remoteStatusRaw!)!
        }
        set {
            remoteStatusRaw = newValue.rawValue
        }
    }
    
    var localAvailable: Bool {
        let availableStates: [CacheState] = [.local, .upload, .uploading, .cached, .unload]
        
        return availableStates.contains(cacheState)
    }
    
    var readyToDownload: Bool {
        return remoteStatus == .available && cacheState == .remote
    }
    
    var progress: Double {
        switch cacheState {
        case .uploading:
            return uploadProgress
        case .downloading:
            return downloadProgress
        default:
            return 0
        }
    }
    
    var url: URL {
        let fileName = recordName! + (suffix ?? "")

        let cacheDirectory: URL
        if let configuredDir = CloudCore.config.cacheDirectoryURL {
            if !FileManager.default.fileExists(atPath: configuredDir.path) {
                try? FileManager.default.createDirectory(at: configuredDir, withIntermediateDirectories: true)
            }
            cacheDirectory = configuredDir
        } else {
            cacheDirectory = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }

        return cacheDirectory.appendingPathComponent(fileName)
    }
    
    var data: Data? {
        if localAvailable == true {
            return try? Data(contentsOf: url)
        } else {
            return nil
        }
    }
    
    func removeLocal() {
        if localAvailable {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
}
