//
//  CloudCoreCacheManager.swift
//  CloudCore
//
//  Created by deeje cooley on 4/16/22.
//

import Foundation
import CoreData
import CloudKit
import Network
#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

@objc
class CloudCoreCacheManager: NSObject {
    
    private let persistentContainer: NSPersistentContainer
    private let observingContext: NSManagedObjectContext
    private let changingContext: NSManagedObjectContext
    private let container: CKContainer
    private let cacheableClassNames: [String]
    
    private var frcs: [NSFetchedResultsController<NSManagedObject>] = []
    
    private var uploadsInFlight = 0
    private var downloadsInFlight = 0
    private var pinnedFRCs: [NSFetchedResultsController<NSManagedObject>] = []
    private var queuedPinnedIDs: [NSManagedObjectID] = []

        // detect cached files purged by the system
    private let verifyQueue = DispatchQueue(label: "CloudCoreCacheManager.verify")
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingVerify: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    public init(persistentContainer: NSPersistentContainer, observingContext: NSManagedObjectContext) {
        self.persistentContainer = persistentContainer
        self.observingContext = observingContext
        self.changingContext = persistentContainer.newBackgroundContext()
        self.changingContext.automaticallyMergesChangesFromParent = true
        
        self.container = CloudCore.config.container
        
        var cacheableClassNames: [String] = []
        let entities = persistentContainer.managedObjectModel.entities
        for entity in entities {
            if let userInfo = entity.userInfo, userInfo[ServiceAttributeNames.keyCacheable] != nil {
                cacheableClassNames.append(entity.managedObjectClassName!)
            }
        }
        self.cacheableClassNames = cacheableClassNames

        super.init()

        verifyCachedFiles()
        restartOperations()
        configureObservers()
        ticklePinnedDownloadsQueue()

        watchCacheDirectory()
        observeAppActivation()
    }

    deinit {
        directorySource?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
    
    func process(cacheables: [CloudCoreCacheable]) {
        for cacheable in cacheables {
            switch cacheable.cacheState {
            case .upload, .uploading:
                upload(cacheableID: cacheable.objectID)
            case .download, .downloading:
                download(cacheableID: cacheable.objectID)
            case .unload:
                unload(cacheableID: cacheable.objectID)
            case .cancel:
                cancelOperation(cacheableID: cacheable.objectID)
            default:
                break
            }
        }
    }
    
    func update(_ cacheableIDs: [NSManagedObjectID], change: @escaping (CloudCoreCacheable) -> Void) {
        let context = changingContext
        context.perform {
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            do {
                for cacheableID in cacheableIDs {
                    if let cacheable = try context.existingObject(with: cacheableID) as? CloudCoreCacheable {
                        change(cacheable)
                    }
                }
                
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                CloudCore.delegate?.error(error: error, module: nil)
            }
        }
    }
    
    func unloadStale() {
        /*
         New properties
         - Last Opened
         
         Discard over X file count
         Discard over Y bytes
         Discard after Z date

         Ignore Pinned (e.g. thumbnails)
         */
        
        let context = changingContext
        context.perform {
            for name in self.cacheableClassNames {
                let pinnedFalse = NSPredicate(format: "%K == %@", "pinned", false)
                let pinnedUnset = NSPredicate(format: "%K == nil", "pinned")
                let unpinned = NSCompoundPredicate(orPredicateWithSubpredicates: [pinnedFalse, pinnedUnset])
                
                let cached = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.cached.rawValue)
                let unpinnedAndCached = NSCompoundPredicate(andPredicateWithSubpredicates: [unpinned, cached])
                
                let unpinnedRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                unpinnedRequest.predicate = unpinnedAndCached
                unpinnedRequest.sortDescriptors = [NSSortDescriptor(key: "lastUsed", ascending: false)]
                
                do {
                    let allUnpinned = try context.fetch(unpinnedRequest) as! [CloudCoreCacheable]
                    
                    var keepCount = CloudCore.config.minCacheCount
                    var cacheSize: Int64 = 0
                    
                    while (cacheSize < CloudCore.config.maxCacheSize) && (keepCount < allUnpinned.count) {
                        let cacheable = allUnpinned[keepCount]
                        cacheSize += cacheable.size
                        keepCount += 1
                    }
                    
                    let stale = allUnpinned.dropFirst(keepCount)
                    
                    for cacheable in stale {
                        self.unload(cacheableID: cacheable.objectID)
                    }
                } catch {
                    print(error)
                }
            }
        }

    }

    /// Finds cacheables whose state says their file is local, but the file is gone (e.g. purged by the system),
    /// and resets them. Cached items go back to .remote, so pinned items re-download automatically and
    /// others re-download when next requested. Unuploaded items get an error, since they can't be recovered.
    func verifyCachedFiles() {
        let context = observingContext

        context.perform {
            let fileManager = FileManager.default

                // one listing per directory, rather than a stat per cacheable
            func fileNames(in directory: URL) -> Set<String>? {
                if !fileManager.fileExists(atPath: directory.path) {
                    return []
                }
                guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
                return Set(fileNames)
            }
            guard let cachedFileNames = fileNames(in: CloudCoreCacheDirectory.url),
                  let persistentFileNames = fileNames(in: CloudCoreCacheDirectory.persistentURL)
            else { return }

            let shouldExistStates: [CacheState] = [.local, .upload, .uploading, .cached, .unload]
            let shouldExist = NSPredicate(format: "%K IN %@", "cacheStateRaw", shouldExistStates.map { $0.rawValue })

            for name in self.cacheableClassNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: name)
                request.predicate = shouldExist
                guard let cacheables = try? context.fetch(request) as? [CloudCoreCacheable] else { continue }

                var misplacedIDs: [NSManagedObjectID] = []
                var missingIDs: [NSManagedObjectID] = []

                for cacheable in cacheables {
                    guard let fileName = cacheable.fileName else { continue }

                    let inPersistent = persistentFileNames.contains(fileName)
                    let inCache = cachedFileNames.contains(fileName)
                    let inPlace = cacheable.needsPersistentStorage ? inPersistent : inCache

                    if inPlace {
                        continue
                    } else if inPersistent || inCache {
                        misplacedIDs.append(cacheable.objectID)
                    } else if cacheable.cacheState == .local || cacheable.cacheState == .upload || cacheable.cacheState == .uploading {
                            // unless already flagged as unrecoverable
                        if cacheable.lastErrorMessage == nil {
                            missingIDs.append(cacheable.objectID)
                        }
                    } else {
                        missingIDs.append(cacheable.objectID)
                    }
                }

                if !misplacedIDs.isEmpty {
                    print("relocating \(misplacedIDs.count) cacheables")
                    self.relocate(misplacedIDs)
                }

                guard !missingIDs.isEmpty else { continue }

                print("resetting \(missingIDs.count) cacheables with missing files")
                self.update(missingIDs) { cacheable in
                        // re-check, the file may have landed since the directories were listed
                    guard !cacheable.relocateIfNeeded() else { return }
                    cacheable.resetForMissingFile(download: false)
                }
            }
        }
    }

    /// Moves files into the location their current state calls for (see `needsPersistentStorage`).
    func relocate(_ cacheableIDs: [NSManagedObjectID]) {
        let context = changingContext
        context.perform {
            for cacheableID in cacheableIDs {
                guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable,
                      cacheable.localAvailable
                else { continue }

                cacheable.relocateIfNeeded()
            }
        }
    }

    /// Debounced, so a burst of file system events results in a single verification.
    func scheduleVerifyCachedFiles(after delay: TimeInterval = 3) {
        verifyQueue.async { [weak self] in
            guard let self else { return }

            self.pendingVerify?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.verifyCachedFiles()
            }
            self.pendingVerify = workItem
            self.verifyQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// Watches the configured cache directory, so files purged while running are detected.
    /// (Application Support, the default, isn't purgeable, so isn't watched.)
    private func watchCacheDirectory() {
        guard CloudCore.config.cacheDirectoryURL != nil else { return }

        verifyQueue.async { [weak self] in
            guard let self else { return }

            self.directorySource?.cancel()
            self.directorySource = nil

            let directory = CloudCoreCacheDirectory.url     // re-creates the directory if needed
            let fileDescriptor = open(directory.path, O_EVTONLY)
            guard fileDescriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor,
                                                                   eventMask: [.write, .delete, .rename],
                                                                   queue: self.verifyQueue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }

                    // the directory itself went away, so watch its replacement
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.watchCacheDirectory()
                }
                self.scheduleVerifyCachedFiles()
            }
            source.setCancelHandler {
                close(fileDescriptor)
            }
            self.directorySource = source
            source.resume()
        }
    }

    /// Files may be purged while the app isn't running or is in the background.
    private func observeAppActivation() {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        let name = UIApplication.willEnterForegroundNotification
        #else
        return
        #endif

        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        activationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.scheduleVerifyCachedFiles(after: 0)
        }
        #endif
    }
    
    private func configureObservers() {
        let context = observingContext
        
        context.performAndWait {
            for name in self.cacheableClassNames {
                    // watch for changes in cache state
                let triggerUpload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.upload.rawValue)
                let triggerDownload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.download.rawValue)
                let triggerUnload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.unload.rawValue)
                let triggerCancel = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.cancel.rawValue)
                let triggers = NSCompoundPredicate(orPredicateWithSubpredicates: [triggerUpload, triggerDownload, triggerUnload, triggerCancel])
                let triggerRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                triggerRequest.predicate = triggers
                triggerRequest.sortDescriptors = [NSSortDescriptor(key: "cacheStateRaw", ascending: true)]
                let frc = NSFetchedResultsController<NSManagedObject>(fetchRequest: triggerRequest,
                                                                      managedObjectContext: context,
                                                                      sectionNameKeyPath: nil,
                                                                      cacheName: nil)
                frc.delegate = self
                try? frc.performFetch()
                if let cacheables = frc.fetchedObjects as? [CloudCoreCacheable] {
                    print("starting \(cacheables.count) cacheable operations")
                    self.process(cacheables: cacheables)
                }
                self.frcs.append(frc)
                
                    // watch for pinned cacheables
                let pinnedRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                let isPinned = NSPredicate(format: "%K == true", "pinned")
                pinnedRequest.predicate = isPinned
                pinnedRequest.sortDescriptors = [NSSortDescriptor(key: "lastUsed", ascending: false)]
                let pinnedFRC = NSFetchedResultsController<NSManagedObject>(fetchRequest: pinnedRequest,
                                                                            managedObjectContext: context,
                                                                            sectionNameKeyPath: nil,
                                                                            cacheName: nil)
                pinnedFRC.delegate = self
                try? pinnedFRC.performFetch()
                if let pinnedCacheables = pinnedFRC.fetchedObjects as? [CloudCoreCacheable] {
                    let pinnedIDs = pinnedCacheables
                                        .filter { $0.cacheState == .remote }
                                        .map { $0.objectID }
                    queuedPinnedIDs.append(contentsOf: pinnedIDs)
                }
                self.pinnedFRCs.append(pinnedFRC)
            }
        }
    }
    
    func restartOperations() {
        let context = observingContext
        
        context.performAndWait {
            for name in self.cacheableClassNames {
                    // retart new & existing ops
                let upload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.upload.rawValue)
                let uploading = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.uploading.rawValue)
                let download = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.download.rawValue)
                let downloading = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.downloading.rawValue)
                let newOrExisting = NSCompoundPredicate(orPredicateWithSubpredicates: [upload, uploading, download, downloading])
                let noError = NSPredicate(format: "%K == nil", "lastErrorMessage")
                let newOrExistingNoError = NSCompoundPredicate(andPredicateWithSubpredicates: [newOrExisting, noError])
                let restoreRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                restoreRequest.predicate = newOrExistingNoError
                if let cacheables = try? context.fetch(restoreRequest) as? [CloudCoreCacheable], !cacheables.isEmpty {
                    print("restarting \(cacheables.count) cacheable operations")
                    self.process(cacheables: cacheables)
                }
                
                let hasError = NSPredicate(format: "%K != nil", "lastErrorMessage")
                
                    // restart uploads
                let isLocal = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.local.rawValue)
                let restartRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                restartRequest.predicate = isLocal
                if let cacheables = try? context.fetch(restartRequest) as? [CloudCoreCacheable], !cacheables.isEmpty {
                    let cacheableIDs = cacheables.map { $0.objectID }
                    self.update(cacheableIDs) { cacheable in
                            // a purged file can't be uploaded, don't keep retrying
                        guard cacheable.relocateIfNeeded() else {
                            cacheable.resetForMissingFile(download: false)
                            return
                        }
                        cacheable.lastErrorMessage = nil
                        cacheable.cacheState = .upload
                    }
                }
                
                // reset failed downloads
                let isRemote = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.remote.rawValue)
                let failedToDownload = NSCompoundPredicate(andPredicateWithSubpredicates: [hasError, isRemote])
                restartRequest.predicate = failedToDownload
                if let cacheables = try? context.fetch(restartRequest) as? [CloudCoreCacheable], !cacheables.isEmpty {
                    let cacheableIDs = cacheables.map { $0.objectID }
                    self.update(cacheableIDs) { cacheable in
                        cacheable.lastErrorMessage = nil
                    }
                }
            }
        }
    }
    
    func findLongLivedOperation(with operationID: String) -> CKOperation? {
        var foundOperation: CKOperation? = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        container.fetchLongLivedOperation(withID: operationID) { operation, error in
            if let error {
                print("Error fetching operation: \(operationID)\n\(error)")
                // Handle error
                // return
            }
            
            foundOperation = operation
            
            semaphore.signal()
        }
        semaphore.wait()
        
        return foundOperation
    }
    
    func longLivedConfiguration(qos: QualityOfService) -> CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.container = container
        configuration.isLongLived = true
        configuration.qualityOfService = qos
        
        return configuration
    }
    
    func upload(cacheableID: NSManagedObjectID) {
            // we've been asked to retry later
        if let date = CloudCore.pauseUntil,
            date.timeIntervalSinceNow > 0
        { return }
        
        self.uploadsInFlight += 1
        
        let container = container
        let context = observingContext
        
        // hmmmm can only pload to your own zone, not sure how that works when adding to a shared record
        var database = container.privateCloudDatabase
        
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable else { return }
            
            var doAdd = false
            
            var uploadOp: CKModifyRecordsOperation!
            if let operationID = cacheable.operationID {
                uploadOp = self.findLongLivedOperation(with: operationID) as? CKModifyRecordsOperation
            }
            
            if uploadOp == nil
            {
                var record = try? cacheable.restoreRecordWithSystemFields(for: .public)
                if record != nil {
                    database = container.publicCloudDatabase
                } else {
                    record = try? cacheable.restoreRecordWithSystemFields(for: .private)
                    
                    if record?.recordID.zoneID.ownerName != CKCurrentUserDefaultName {
                        database = container.sharedCloudDatabase
                    }
                }
                
                guard let record else { return }
                
                record[cacheable.assetFieldName] = CKAsset(fileURL: cacheable.url)
                record["remoteStatusRaw"] = RemoteStatus.available.rawValue
                
                uploadOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
                uploadOp.configuration = self.longLivedConfiguration(qos: .utility)
                uploadOp.savePolicy = .changedKeys
                
                cacheable.operationID = uploadOp.operationID
                
                doAdd = true
            }
            
            uploadOp.perRecordProgressBlock = { record, progress in
                self.update([cacheableID]) { cacheable in
                    if progress > cacheable.uploadProgress {
                        cacheable.uploadProgress = progress
                    }
                }
            }
            uploadOp.perRecordSaveBlock = { recordID, result in
                var success = true
                var errorMessage: String?
                
                if case let .failure(error) = result {
                    success = false
                    
                    if let cloudError = error as? CKError,
                       let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber
                    {
                        CloudCore.pauseUntil = Date(timeIntervalSinceNow: number.doubleValue)
                    } else {
                        errorMessage = error.localizedDescription
                        
                        CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                    }
                }
                
                self.update([cacheableID]) { cacheable in
                    cacheable.uploadProgress = 0
                    cacheable.cacheState = success ? .cached : .local
                    cacheable.remoteStatus = success ? .available : .pending
                    cacheable.lastErrorMessage = errorMessage

                    if success {
                        cacheable.lastUsed = Date()

                            // safely in CloudKit now, so unless pinned, it can live in the purgeable cache
                        cacheable.relocateIfNeeded()
                    }
                }
            }
            uploadOp.modifyRecordsResultBlock = { result in
                self.unloadStale()
                
                self.uploadsInFlight -= 1
                if self.uploadsInFlight < 0 {
                    self.uploadsInFlight = 0
                }
            }
            uploadOp.longLivedOperationWasPersistedBlock = { }
            
            if doAdd {
                database.add(uploadOp)
            }
            
            if cacheable.cacheState != .uploading {
                cacheable.cacheState = .uploading
            }
            if context.hasChanges {
                try? context.save()
            }
        }
    }
    
    func download(cacheableID: NSManagedObjectID) {
            // we've been asked to retry later
        if let date = CloudCore.pauseUntil,
            date.timeIntervalSinceNow > 0
        { return }
        
        self.downloadsInFlight += 1
        
        let container = container
        let context = observingContext
        
        var database = container.privateCloudDatabase
        
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable else { return }
            
            var doAdd = false
            
            var downloadOp: CKFetchRecordsOperation!
            if let operationID = cacheable.operationID {
                downloadOp = self.findLongLivedOperation(with: operationID) as? CKFetchRecordsOperation
            }
            
            if downloadOp == nil
            {
                var record = try? cacheable.restoreRecordWithSystemFields(for: .public)
                if record != nil {
                    database = container.publicCloudDatabase
                } else {
                    record = try? cacheable.restoreRecordWithSystemFields(for: .private)
                    
                    if record?.recordID.zoneID.ownerName != CKCurrentUserDefaultName {
                        database = container.sharedCloudDatabase
                    }
                }
                
                guard let record else { return }
                
                downloadOp = CKFetchRecordsOperation(recordIDs: [record.recordID])
                downloadOp.configuration = self.longLivedConfiguration(qos: .userInitiated)
                downloadOp.desiredKeys = [cacheable.assetFieldName]
                
                cacheable.operationID = downloadOp.operationID
                
                doAdd = true
            }
            
            downloadOp.perRecordProgressBlock = { record, progress in
                self.update([cacheableID]) { cacheable in
                    if progress > cacheable.downloadProgress {
                        cacheable.downloadProgress = progress
                    }
                }
            }
            downloadOp.perRecordResultBlock = { recordID, result in
                var record: CKRecord?
                var success = true
                var errorMessage: String?
                
                switch result
                {
                case .success(let fetchedRecord):
                    record = fetchedRecord
                case .failure(let error):
                    success = false
                    
                    if let cloudError = error as? CKError,
                       let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber
                    {
                        CloudCore.pauseUntil = Date(timeIntervalSinceNow: number.doubleValue)
                    } else {
                        errorMessage = error.localizedDescription
                        
                        CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                    }
                }

                self.update([cacheableID]) { cacheable in
                    var message = errorMessage
                    var moved = false

                    if success {
                        if let asset = record?[cacheable.assetFieldName] as? CKAsset,
                           let downloadURL = asset.fileURL
                        {
                            let fileManager = FileManager.default
                            let destination = cacheable.url

                            do {
                                    // a stale or partial file would make the move fail
                                if fileManager.fileExists(atPath: destination.path) {
                                    try fileManager.removeItem(at: destination)
                                }
                                try fileManager.moveItem(at: downloadURL, to: destination)
                                moved = true
                            } catch {
                                message = error.localizedDescription
                                CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                            }
                        } else {
                            message = "Downloaded record has no asset"
                        }
                    }

                    cacheable.downloadProgress = 0
                    cacheable.cacheState = moved ? .cached : .remote
                    cacheable.lastErrorMessage = message
                    if moved {
                        cacheable.lastUsed = Date()
                    }
                }
            }
            downloadOp.fetchRecordsResultBlock = { result in
                self.unloadStale()
                
                self.downloadsInFlight -= 1
                if self.downloadsInFlight < 0 {
                    self.downloadsInFlight = 0
                }
            }
            downloadOp.longLivedOperationWasPersistedBlock = { }
            
            if doAdd {
                database.add(downloadOp)
            }
            
            if cacheable.cacheState != .downloading {
                cacheable.cacheState = .downloading
            }
            if context.hasChanges {
                try? context.save()
            }
        }
    }
    
    func unload(cacheableID: NSManagedObjectID) {
        update([cacheableID]) { cacheable in
            cacheable.removeLocal()
            cacheable.cacheState = .remote
        }
    }
    
    func cancelOperation(cacheableID: NSManagedObjectID) {
        update([cacheableID]) { cacheable in
            if let operationID = cacheable.operationID {
                self.cancelOperations(with: [operationID])
                cacheable.operationID = nil
            }
            if cacheable.remoteStatus == .pending {
                cacheable.cacheState = .local
            } else if cacheable.remoteStatus == .available {
                cacheable.cacheState = .remote
            }
        }
    }
    
    public func cancelOperations(with operationIDs: [String]) {
        for operationID in operationIDs {
            if let op = findLongLivedOperation(with: operationID) {
                op.cancel()
            }
        }
    }
    
    func ticklePinnedDownloadsQueue() {
        let maxPinnedDownloads = 20
        let availableDownloads = maxPinnedDownloads - downloadsInFlight
        if availableDownloads > 0, queuedPinnedIDs.count > 0 {
            let idsToDownload = queuedPinnedIDs.prefix(availableDownloads)
            queuedPinnedIDs.removeFirst(idsToDownload.count)
            idsToDownload.forEach { download(cacheableID: $0) }
        }
    }
    
}

extension CloudCoreCacheManager: NSFetchedResultsControllerDelegate {
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>,
                    didChange anObject: Any,
                    at indexPath: IndexPath?,
                    for type: NSFetchedResultsChangeType,
                    newIndexPath: IndexPath?) {
        guard let cacheable = anObject as? CloudCoreCacheable else { return }

            // pinned or unpinned, so the file belongs in the other location
        if type == .insert || type == .delete,
           cacheable.localAvailable,
           pinnedFRCs.contains(where: { $0 === controller })
        {
            relocate([cacheable.objectID])
        }

        switch cacheable.cacheState {
        case .upload, .download, .unload, .cancel:
            process(cacheables: [cacheable])
        default:
            if cacheable.pinned,
                cacheable.cacheState == .remote,
                cacheable.remoteStatus == .available,
                !queuedPinnedIDs.contains(cacheable.objectID)
            {
                queuedPinnedIDs.append(cacheable.objectID)
            } else if !cacheable.pinned, let index = queuedPinnedIDs.firstIndex(of: cacheable.objectID) {
                queuedPinnedIDs.remove(at: index)
            }
        }
    }
    
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        ticklePinnedDownloadsQueue()
    }
    
}
