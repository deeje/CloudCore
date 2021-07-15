//
//  PullRecordOperation.swift
//  CloudCore
//
//  Created by deeje cooley on 3/23/21.
//

import CloudKit
import CoreData

/// An operation that fetches data from CloudKit for one record and all its child records, and saves it to Core Data
public class PullRecordOperation: PullOperation {
    
    let rootRecordID: CKRecord.ID
    let database: CKDatabase
    
    var fetchedRecordIDs: [CKRecord.ID] = []
    
    public init(rootRecordID: CKRecord.ID, database: CKDatabase, persistentContainer: NSPersistentContainer) {
        self.rootRecordID = rootRecordID
        self.database = database
        
        super.init(persistentContainer: persistentContainer)
        
        name = "PullRecordOperation"
    }
    
    override public func main() {
        if self.isCancelled { return }
        
        #if TARGET_OS_IOS
        let app = UIApplication.shared
        var backgroundTaskID = app.beginBackgroundTask(withName: name) {
            app.endBackgroundTask(backgroundTaskID!)
        }
        defer {
            app.endBackgroundTask(backgroundTaskID!)
        }
        #endif
        
        CloudCore.delegate?.willSyncFromCloud()
        
        let backgroundContext = persistentContainer.newBackgroundContext()
        backgroundContext.name = CloudCore.config.pullContextName
        
        addFetchRecordsOp(recordIDs: [rootRecordID], backgroundContext: backgroundContext)
        
        self.queue.waitUntilAllOperationsAreFinished()
        
        self.processMissingReferences(context: backgroundContext)
        
        backgroundContext.performAndWait {
            do {
                try backgroundContext.save()
            } catch {
                errorBlock?(error)
            }
        }
                
        CloudCore.delegate?.didSyncFromCloud()
    }
    
    private func addFetchRecordsOp(recordIDs: [CKRecord.ID], backgroundContext: NSManagedObjectContext) {
        let fetchRecords = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchRecords.database = database
        fetchRecords.qualityOfService = .userInteractive
        fetchRecords.perRecordCompletionBlock = { record, recordID, error in
            if let record = record {
                self.fetchedRecordIDs.append(recordID!)
                
                self.addConvertRecordOperation(record: record, context: backgroundContext)
                
                var childIDs: [CKRecord.ID] = []
                record.allKeys().forEach { key in
                    if let reference = record[key] as? CKRecord.Reference, !self.fetchedRecordIDs.contains(reference.recordID) {
                        childIDs.append(reference.recordID)
                    }
                    if let array = record[key] as? [CKRecord.Reference] {
                        array.forEach { reference in
                            if !self.fetchedRecordIDs.contains(reference.recordID) {
                                childIDs.append(reference.recordID)
                            }
                        }
                    }
                }
                
                if !childIDs.isEmpty {
                    self.addFetchRecordsOp(recordIDs: childIDs, backgroundContext: backgroundContext)
                }
            }
        }
        let finished = BlockOperation { }
        finished.addDependency(fetchRecords)
        database.add(fetchRecords)
        self.queue.addOperation(finished)
    }
    
}
