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
        return directory(CloudCore.config.cacheDirectoryURL)
    }

    /// the configured persistent directory (created if needed), else Application Support
    static var persistentURL: URL {
        return directory(CloudCore.config.persistentDirectoryURL)
    }

    private static func directory(_ configuredDir: URL?) -> URL {
        if let configuredDir {
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
    
    /// Pinned files, and files that only exist locally (not yet in CloudKit), must survive
    /// the system purging the cache directory. Based on cacheState, which isn't synced, so
    /// a pull can't move the goalposts mid-upload.
    var needsPersistentStorage: Bool {
        if pinned { return true }

        switch cacheState {
        case .local, .upload, .uploading:
            return true
        case .cancel:
            return remoteStatus == .pending
        default:
            return false
        }
    }

    var url: URL {
        return needsPersistentStorage ? persistentFileURL : cacheFileURL
    }

    internal var persistentFileURL: URL {
        return CloudCoreCacheDirectory.persistentURL.appendingPathComponent(fileName!)
    }

    internal var cacheFileURL: URL {
        return CloudCoreCacheDirectory.url.appendingPathComponent(fileName!)
    }

    /// whichever of the two locations `url` isn't
    internal var alternateURL: URL {
        return needsPersistentStorage ? cacheFileURL : persistentFileURL
    }

    /// Returns true if the file is at `url`. If instead it's in the other location (pinned state
    /// changed, upload just completed, or a file from before persistent storage existed),
    /// moves it to `url` and returns true. Returns false if it's in neither.
    @discardableResult
    func relocateIfNeeded() -> Bool {
        guard fileName != nil else { return false }

        let fileManager = FileManager.default
        let destination = url
        if fileManager.fileExists(atPath: destination.path) { return true }

        let source = alternateURL
        guard source != destination, fileManager.fileExists(atPath: source.path) else { return false }

        do {
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
                // a concurrent relocation may have won the race
            if fileManager.fileExists(atPath: destination.path) { return true }

            CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                // still readable where it is, try again next time
            return false
        }
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
        if relocateIfNeeded() { return true }

        guard let context = managedObjectContext else { return false }
        let cacheableID = objectID
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable,
                  cacheable.localAvailable,
                  !cacheable.relocateIfNeeded()
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
        guard localAvailable, fileName != nil else { return }

            // could be in either location, mid-relocation
        try? FileManager.default.removeItem(at: persistentFileURL)
        try? FileManager.default.removeItem(at: cacheFileURL)
    }
    
}
