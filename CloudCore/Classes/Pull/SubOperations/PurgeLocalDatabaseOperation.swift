//
//  PurgeLocalDatabaseOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 12/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData

#if os(iOS)
import UIKit
#endif

class PurgeLocalDatabaseOperation: Operation, @unchecked Sendable {
	
	let parentContext: NSManagedObjectContext
	let managedObjectModel: NSManagedObjectModel
	var errorBlock: ErrorBlock?
	
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier?
    #endif
    
	init(parentContext: NSManagedObjectContext, managedObjectModel: NSManagedObjectModel) {
		self.parentContext = parentContext
		self.managedObjectModel = managedObjectModel
		
		super.init()
        
        name = "PurgeLocalDatabaseOperation"
        qualityOfService = .userInitiated
	}
	
	override func main() {
		super.main()
        
		let childContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        childContext.performAndWait {
            childContext.parent = parentContext
            
            for entity in managedObjectModel.cloudCoreEnabledEntities {
                guard let entityName = entity.name else { continue }
                
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                fetchRequest.includesPropertyValues = false
                
                do {
                    // I don't user `NSBatchDeleteRequest` because we can't notify viewContextes about changes
                    guard let objects = try childContext.fetch(fetchRequest) as? [NSManagedObject] else { continue }
                    
                    for object in objects {
                        childContext.delete(object)
                    }
                } catch {
                    errorBlock?(error)
                }
            }
            
            do {
                try childContext.save()
            } catch {
                errorBlock?(error)
            }
        }
	}
	

	
}
