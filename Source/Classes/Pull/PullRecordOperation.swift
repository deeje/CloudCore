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
        
        CloudCore.delegate?.willSyncFromCloud(scope: database.databaseScope)
        
        let backgroundContext = persistentContainer.newBackgroundContext()
        backgroundContext.name = CloudCore.config.pullContextName
        
        addFetchRecordsOp(recordIDs: [rootRecordID], database: database, backgroundContext: backgroundContext)
        
        self.queue.waitUntilAllOperationsAreFinished()
        
        self.processMissingReferences(context: backgroundContext)
        
        backgroundContext.performAndWait {
            do {
                try backgroundContext.save()
            } catch {
                errorBlock?(error)
            }
        }
                
        CloudCore.delegate?.didSyncFromCloud(scope: database.databaseScope)
    }
        
}
