//
//  PullChangesOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

/// An operation that fetches data from CloudKit and saves it to Core Data, you can use it without calling `CloudCore.pull` methods if you application relies on `Operation`
public class PullChangesOperation: PullOperation {
	
	/// Private cloud database for the CKContainer specified by CloudCoreConfig
	public static let allDatabases = [
//		CloudCore.config.container.publicCloudDatabase,
		CloudCore.config.container.privateCloudDatabase,
		CloudCore.config.container.sharedCloudDatabase
	]
    
	private let databases: [CKDatabase]
    private let tokens: Tokens
    
	/// Initialize operation, it's recommended to set `errorBlock`
	///
	/// - Parameters:
	///   - databases: list of databases to fetch data from (only private is supported now)
	///   - persistentContainer: `NSPersistentContainer` that will be used to save data
	///   - tokens: previously saved `Tokens`, you can generate new ones if you want to fetch all data
	public init(from databases: [CKDatabase] = PullChangesOperation.allDatabases,
                persistentContainer: NSPersistentContainer,
                tokens: Tokens = CloudCore.tokens) {
		self.databases = databases
        self.tokens = tokens
        
        super.init(persistentContainer: persistentContainer)
        
        name = "PullChangesOperation"
	}
	
	/// Performs the receiver’s non-concurrent task.
	override public func main() {
		if isCancelled { return }
        
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
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        for database in databases {
            let databaseChangeToken = tokens.token(for: database.databaseScope)
            
            if database.databaseScope == .public {
                PublicDatabaseSubscriptions.pull(into: persistentContainer)
            } else {
                var changedZoneIDs = [CKRecordZone.ID]()
                var deletedZoneIDs = [CKRecordZone.ID]()
                
                let fetchDatabaseChanges = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
                fetchDatabaseChanges.database = database
                fetchDatabaseChanges.qualityOfService = .userInitiated
                fetchDatabaseChanges.recordZoneWithIDChangedBlock = { recordZoneID in
                    changedZoneIDs.append(recordZoneID)
                }
                fetchDatabaseChanges.recordZoneWithIDWasDeletedBlock = { recordZoneID in
                    deletedZoneIDs.append(recordZoneID)
                }
                fetchDatabaseChanges.fetchDatabaseChangesResultBlock = { result in
                    switch result {
                    case .success(let (changeToken, moreComing)):
                        if changedZoneIDs.count > 0 {
                            self.addRecordZoneChangesOperation(recordZoneIDs: changedZoneIDs, database: database, context: backgroundContext)
                        }
                        if deletedZoneIDs.count > 0 {
                            self.deleteRecordsFromDeletedZones(recordZoneIDs: deletedZoneIDs)
                        }
                        
                        self.tokens.setToken(changeToken, for: database.databaseScope)
                        
                        // TODO: handle moreComing
                    case .failure(let error):
                        // TODO: error handling?
                        break
                    }
                }
                /*
                 To improve performance overall, and on watchOS in particular
                 make sure to queue up CK operations on the proper queue
                 whether its for the container in general or a specific database.
                 
                 To maintain the overall logic of CloudCore, we shadow these ops
                 in our own queues, using no-op block ops with dependencies.
                 
                 You will see this pattern elsewhere in CloudCore when appropriate.
                 */
                let finished = BlockOperation { }
                finished.addDependency(fetchDatabaseChanges)
                database.add(fetchDatabaseChanges)
                queue.addOperation(finished)
            }
        }
        
		queue.waitUntilAllOperationsAreFinished()
        
        processMissingReferences(context: backgroundContext)
        
        backgroundContext.performAndWait {
            do {
                try backgroundContext.save()
            } catch {
                errorBlock?(error)
            }
        }
		
        tokens.saveToUserDefaults()
        
		CloudCore.delegate?.didSyncFromCloud()
	}
    
    private func addDeleteRecordOperation(recordID: CKRecord.ID, context: NSManagedObjectContext) {
        // Delete NSManagedObject with specified recordID Operation
        let deleteOperation = DeleteFromCoreDataOperation(parentContext: context, recordID: recordID)
        deleteOperation.errorBlock = { self.errorBlock?($0) }
        queue.addOperation(deleteOperation)
    }
    
    private func addRecordZoneChangesOperation(recordZoneIDs: [CKRecordZone.ID], database: CKDatabase, context: NSManagedObjectContext) {
		if recordZoneIDs.isEmpty { return }
		
        let desiredKeys = context.persistentStoreCoordinator?.managedObjectModel.desiredKeys
        
        let recordZoneChangesOperation = FetchRecordZoneChangesOperation(from: database,
                                                                         recordZoneIDs: recordZoneIDs,
                                                                         tokens: tokens,
                                                                         desiredKeys: desiredKeys)
        recordZoneChangesOperation.qualityOfService = .userInitiated
		recordZoneChangesOperation.recordChangedBlock = {
            self.addConvertRecordOperation(record: $0, context: context)
		}
		
		recordZoneChangesOperation.recordWithIDWasDeletedBlock = {
            self.addDeleteRecordOperation(recordID: $0, context: context)
		}
		
		recordZoneChangesOperation.errorBlock = { zoneID, error in
			self.handle(recordZoneChangesError: error, in: zoneID, database: database, context: context)
		}
        
        let commitChanges = {
            self.processMissingReferences(context: context)
            
            context.performAndWait {
                do {
                    try context.save()
                } catch {
                    self.errorBlock?(error)
                }
            }
        }
        
        recordZoneChangesOperation.tokenUpdatedBlock = {
            commitChanges()
        }
        
        recordZoneChangesOperation.completionBlock = {
            commitChanges()
        }
		
		queue.addOperation(recordZoneChangesOperation)
	}
    
    private func deleteRecordsFromDeletedZones(recordZoneIDs: [CKRecordZone.ID]) {
        persistentContainer.performBackgroundTask { moc in
            for entity in self.persistentContainer.managedObjectModel.entities {
                if let serviceAttributes = entity.serviceAttributeNames {
                    for recordZoneID in recordZoneIDs {
                        do {
                            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity.name!)
                            request.predicate = NSPredicate(format: "%K == %@", serviceAttributes.ownerName, recordZoneID.ownerName)
                            let results = try moc.fetch(request) as! [NSManagedObject]
                            for object in results {
                                moc.delete(object)
                            }
                        } catch {
                            print("Unexpected error: \(error).")
                        }
                    }
                }
            }
            
            do {
                try moc.save()
            } catch {
                print("Unexpected error: \(error).")
            }
        }
    }

    private func handle(recordZoneChangesError: Error, in zoneID: CKRecordZone.ID, database: CKDatabase, context: NSManagedObjectContext) {
		guard let cloudError = recordZoneChangesError as? CKError else {
			errorBlock?(recordZoneChangesError)
			return
		}
		
		switch cloudError.code {
		// User purged cloud database, we need to delete local cache (according Apple Guidelines)
		case .userDeletedZone:
			queue.cancelAllOperations()
			
			let purgeOperation = PurgeLocalDatabaseOperation(parentContext: context, managedObjectModel: persistentContainer.managedObjectModel)
			purgeOperation.errorBlock = errorBlock
			queue.addOperation(purgeOperation)
			
		// Our token is expired, we need to refetch everything again
		case .changeTokenExpired:
            tokens.setToken(nil, for: zoneID)
			addRecordZoneChangesOperation(recordZoneIDs: [zoneID], database: database, context: context)
            
		default:
            errorBlock?(cloudError)
		}
	}
	
}
