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
    private let processContext: NSManagedObjectContext
    private let container: CKContainer
    private let cacheableClassNames: [String]
    
    private var frcs: [NSFetchedResultsController<NSManagedObject>] = []
    
    public init(persistentContainer: NSPersistentContainer, processContext: NSManagedObjectContext) {
        self.persistentContainer = persistentContainer
        self.processContext = processContext
        
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
            default:
                break
            }
        }
    }
    
    func update(_ cacheableIDs: [NSManagedObjectID], change: @escaping (CloudCoreCacheable) -> Void) {
        persistentContainer.performBackgroundTask { context in
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
    
    private func configureObservers() {
        let context = processContext
        
        context.perform {
            for name in self.cacheableClassNames {
                let triggerUpload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.upload.rawValue)
                let triggerDownload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.download.rawValue)
                let triggerUnload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.unload.rawValue)
                let triggers = NSCompoundPredicate(orPredicateWithSubpredicates: [triggerUpload, triggerDownload, triggerUnload])
                
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
                    self.process(cacheables: cacheables)
                }
                
                self.frcs.append(frc)
            }
        }
    }
    
    func restartOperations() {
        let context = processContext
        
        context.perform {
            for name in self.cacheableClassNames {
                    // retart new & existing ops
                let upload = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.upload.rawValue)
                let uploading = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.uploading.rawValue)
                let download = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.download.rawValue)
                let downloading = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.downloading.rawValue)
                let newOrExisting = NSCompoundPredicate(orPredicateWithSubpredicates: [upload, uploading, download, downloading])
                let restoreRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                restoreRequest.predicate = newOrExisting
                if let cacheables = try? context.fetch(restoreRequest) as? [CloudCoreCacheable], !cacheables.isEmpty {
                    self.process(cacheables: cacheables)
                }
                
                    // restart failed uploads
                let hasError = NSPredicate(format: "%K != nil", "lastErrorMessage")
                let isLocal = NSPredicate(format: "%K == %@", "cacheStateRaw", CacheState.local.rawValue)
                let failedToUpload = NSCompoundPredicate(orPredicateWithSubpredicates: [hasError, isLocal])
                let restartRequest = NSFetchRequest<NSManagedObject>(entityName: name)
                restartRequest.predicate = failedToUpload
                if let cacheables = try? context.fetch(restartRequest) as? [CloudCoreCacheable], !cacheables.isEmpty {
                    let cacheableIDs = cacheables.map { $0.objectID }
                    self.update(cacheableIDs) { cacheable in
                        cacheable.lastErrorMessage = nil
                        cacheable.cacheState = .upload
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
        let context = processContext
        
        // hmmmm can only pload to your own zone, not sure how that works when adding to a shared record
        var database = container.privateCloudDatabase
        
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable else { return }
            
            var modifyOp: CKModifyRecordsOperation!
            if let operationID = cacheable.operationID {
                modifyOp = self.findLongLivedOperation(with: operationID) as? CKModifyRecordsOperation
            }
            
            if modifyOp == nil
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
                
                modifyOp = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
                modifyOp.configuration = self.longLivedConfiguration(qos: .utility)
                modifyOp.savePolicy = .changedKeys
                
                cacheable.operationID = modifyOp.operationID
            }
            
            modifyOp.perRecordProgressBlock = { record, progress in
                self.update([cacheableID]) { cacheable in
                    if progress > cacheable.uploadProgress {
                        cacheable.uploadProgress = progress
                    }
                }
            }
            modifyOp.perRecordSaveBlock = { recordID, result in
                var success = true
                var errorMessage: String?
                
                if case let .failure(error) = result {
                    success = false
                    errorMessage = error.localizedDescription
                    
                    CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                    
                    if let cloudError = error as? CKError,
                       let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber
                    {
                        CloudCore.pauseUntil = Date(timeIntervalSinceNow: number.doubleValue)
                    }
                }
                
                self.update([cacheableID]) { cacheable in
                    cacheable.uploadProgress = 0
                    cacheable.cacheState = success ? .cached : .local
                    cacheable.remoteStatus = success ? .available : .pending
                    cacheable.lastErrorMessage = errorMessage
                }
            }
            modifyOp.modifyRecordsResultBlock = { result in }
            modifyOp.longLivedOperationWasPersistedBlock = { }
            if !modifyOp.isExecuting {
                database.add(modifyOp)
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
        let context = processContext
        
        var database = container.privateCloudDatabase
        
        context.perform {
            guard let cacheable = try? context.existingObject(with: cacheableID) as? CloudCoreCacheable else { return }
            
            var fetchOp: CKFetchRecordsOperation!
            if let operationID = cacheable.operationID {
                fetchOp = self.findLongLivedOperation(with: operationID) as? CKFetchRecordsOperation
            }
            
            if fetchOp == nil
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
                
                fetchOp = CKFetchRecordsOperation(recordIDs: [record.recordID])
                fetchOp.configuration = self.longLivedConfiguration(qos: .userInitiated)
                fetchOp.desiredKeys = [cacheable.assetFieldName]
                
                cacheable.operationID = fetchOp.operationID
            }
            
            fetchOp.perRecordProgressBlock = { record, progress in
                self.update([cacheableID]) { cacheable in
                    if progress > cacheable.downloadProgress {
                        cacheable.downloadProgress = progress
                    }
                }
            }
            fetchOp.perRecordResultBlock = { recordID, result in
                var record: CKRecord?
                var success = true
                var errorMessage: String?
                
                switch result
                {
                case .success(let fetchedRecord):
                    record = fetchedRecord
                case .failure(let error):
                    success = false
                    errorMessage = error.localizedDescription
                    
                    CloudCore.delegate?.error(error: error, module: .cacheToCloud)
                    
                    if let cloudError = error as? CKError,
                       let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber
                    {
                        CloudCore.pauseUntil = Date(timeIntervalSinceNow: number.doubleValue)
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
                }

            }
            fetchOp.longLivedOperationWasPersistedBlock = { }
            if !fetchOp.isExecuting {
                database.add(fetchOp)
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
        
        if cacheable.cacheState == .upload
            || cacheable.cacheState == .download
            || cacheable.cacheState == .unload
        {
            process(cacheables: [cacheable])
        }
    }
    
}
