//
//  PullRecordOperation.swift
//  CloudCore
//
//  Created by deeje cooley on 3/23/21.
//

import CloudKit
import CoreData

#if os(iOS)
import UIKit
#endif

/// An operation that fetches data from CloudKit for one record and all its child records, and saves it to Core Data
public class PullRecordOperation: PullOperation, @unchecked Sendable {
    
    let rootRecordID: CKRecord.ID
    let database: CKDatabase
    
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier?
    #endif
    
    public init(rootRecordID: CKRecord.ID, database: CKDatabase, persistentContainer: NSPersistentContainer) {
        self.rootRecordID = rootRecordID
        self.database = database
        
        super.init(persistentContainer: persistentContainer)
        
        name = "PullRecordOperation"
    }
    
    override public func main() {
        if self.isCancelled { return }
        
        #if os(iOS)
        let app = UIApplication.shared
        backgroundTaskID = app.beginBackgroundTask(withName: name) {
            if let taskID = self.backgroundTaskID {
                app.endBackgroundTask(taskID)
            }
            self.backgroundTaskID = nil
        }
        defer {
            if let taskID = self.backgroundTaskID {
                app.endBackgroundTask(taskID)
            }
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
