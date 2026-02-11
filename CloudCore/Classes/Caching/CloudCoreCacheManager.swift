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

@objc
class CloudCoreCacheManager: NSObject {
    
    private let persistentContainer: NSPersistentContainer
    private let observingContext: NSManagedObjectContext
    private let changingContext: NSManagedObjectContext
    private let container: CKContainer
    private let cacheableClassNames: [String]
    
    private var frcs: [NSFetchedResultsController<NSManagedObject>] = []
    
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
        
        restartOperations()
        configureObservers()
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
    
    private func configureObservers() {
        let context = observingContext
        
        context.perform {
            for name in self.cacheableClassNames {
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
            }
        }
    }
    
    func restartOperations() {
        let context = observingContext
        
        context.perform {
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
                    }
                }
            }
            uploadOp.modifyRecordsResultBlock = { result in
                self.unloadStale()
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
                    if let asset = record?[cacheable.assetFieldName] as? CKAsset,
                       let downloadURL = asset.fileURL
                    {
                        let fileManager = FileManager.default
                        
                        try? fileManager.moveItem(at: downloadURL, to: cacheable.url)
                    }
                    
                    cacheable.downloadProgress = 0
                    cacheable.cacheState = success ? .cached : .remote
                    cacheable.lastErrorMessage = errorMessage
                    if success {
                        cacheable.lastUsed = Date()
                    }
                }
            }
            downloadOp.fetchRecordsResultBlock = { result in
                self.unloadStale()
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
    
}

extension CloudCoreCacheManager: NSFetchedResultsControllerDelegate {
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>,
                    didChange anObject: Any,
                    at indexPath: IndexPath?,
                    for type: NSFetchedResultsChangeType,
                    newIndexPath: IndexPath?) {
        guard let cacheable = anObject as? CloudCoreCacheable else { return }
        
        switch cacheable.cacheState {
        case .upload, .download, .unload, .cancel:
            process(cacheables: [cacheable])
        default:
            break
        }
    }
    
}
