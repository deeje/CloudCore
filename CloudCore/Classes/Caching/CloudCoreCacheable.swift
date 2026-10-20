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

enum CloudCoreCacheableError {
    static let localFileMissing = "Local file missing"
}

enum CloudCoreCacheDirectory {

    /// the configured cache directory (created if needed), else Application Support
    static var url: URL {
        if let configuredDir = CloudCore.config.cacheDirectoryURL {
            if !FileManager.default.fileExists(atPath: configuredDir.path) {
                try? FileManager.default.createDirectory(at: configuredDir, withIntermediateDirectories: true)
            }
            return configuredDir
        } else {
            return try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
    }

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
        return CloudCoreCacheDirectory.url.appendingPathComponent(fileName!)
    }

    /// name of the file within the cache directory
    internal var fileName: String? {
        guard let recordName else { return nil }

        return recordName + (suffix ?? "")
    }
    
    var data: Data? {
        guard ensureLocalFile() else { return nil }

        return try? Data(contentsOf: url)
    }

    /// Returns true if the file is actually on disk.
    ///
    /// The system can purge cache directories (e.g. Library/Caches), so `cacheState` may claim a file is local
    /// when it's gone. In that case, the state is reset so CloudCore re-downloads it (→ .download if available
    /// remotely, else → .remote), and false is returned. Call sites observing the cacheable will update once
    /// the download completes. Must be called on the object's context queue.
    @discardableResult
    func ensureLocalFile() -> Bool {
        guard localAvailable else { return false }
        if FileManager.default.fileExists(atPath: url.path) { return true }

        guard let context = managedObjectContext else { return false }
        let cacheableID = objectID
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable,
                  cacheable.localAvailable,
                  !FileManager.default.fileExists(atPath: cacheable.url.path)
            else { return }

            cacheable.resetForMissingFile(download: true)

            if context.hasChanges {
                try? context.save()
            }
        }

        return false
    }

    /// Resets state for a cacheable whose local file has gone missing.
    internal func resetForMissingFile(download: Bool) {
        switch cacheState {
        case .cached:
            operationID = nil
            downloadProgress = 0
            if download && remoteStatus == .available {
                cacheState = .download
            } else {
                cacheState = .remote
            }
        case .unload:
                // was being removed anyway
            cacheState = .remote
        case .local, .upload, .uploading:
                // never made it to CloudKit, so nothing to recover from
            if lastErrorMessage == nil {
                lastErrorMessage = CloudCoreCacheableError.localFileMissing
            }
        default:
            break
        }
    }
    
    func removeLocal() {
        if localAvailable {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
}
