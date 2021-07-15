//
//  DeleteFromCoreDataOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

class DeleteFromCoreDataOperation: Operation {
	let parentContext: NSManagedObjectContext
    let recordID: CKRecord.ID
	var errorBlock: ErrorBlock?
    
    init(parentContext: NSManagedObjectContext, recordID: CKRecord.ID) {
		self.parentContext = parentContext
		self.recordID = recordID
		
		super.init()
		
        name = "DeleteFromCoreDataOperation"
        qualityOfService = .userInteractive
	}
	
	override func main() {
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
        
		let childContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        childContext.performAndWait {
            childContext.parent = parentContext
            
            // Iterate through each entity to fetch and delete object with our recordData
            guard let entities = childContext.persistentStoreCoordinator?.managedObjectModel.entities else { return }
            for entity in entities {
                guard let serviceAttributeNames = entity.serviceAttributeNames else { continue }
                
                do {
                    let deleted = try self.delete(entityName: serviceAttributeNames.entityName,
                                                  attributeNames: serviceAttributeNames,
                                                  in: childContext)
                    
                    // only 1 record with such recordData may exists, if delete we don't need to fetch other entities
                    if deleted { break }
                } catch {
                    self.errorBlock?(error)
                    continue
                }
            }
            
            do {
                try childContext.save()
            } catch {
                self.errorBlock?(error)
            }
        }
	}
	
	/// Delete NSManagedObject with specified recordData from entity
	///
	/// - Returns: `true` if object is found and deleted, `false` is object is not found
	private func delete(entityName: String, attributeNames: ServiceAttributeNames, in context: NSManagedObjectContext) throws -> Bool {
		let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
		fetchRequest.includesPropertyValues = false
		fetchRequest.predicate = NSPredicate(format: attributeNames.recordName + " = %@", recordID.recordName)
		
		guard let objects = try context.fetch(fetchRequest) as? [NSManagedObject] else { return false }
		if objects.isEmpty { return false }
		
		for object in objects {
			context.delete(object)
		}
		
		return true
	}
	
}
