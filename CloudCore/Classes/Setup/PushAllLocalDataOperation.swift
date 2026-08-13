//
//  UploadAllLocalDataOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 12/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CoreData

#if os(iOS)
import UIKit
#endif

class PushAllLocalDataOperation: Operation, @unchecked Sendable {
	
	let managedObjectModel: NSManagedObjectModel
	let parentContext: NSManagedObjectContext
	
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier?
    #endif
    
	var errorBlock: ErrorBlock? {
		didSet {
			converter.errorBlock = errorBlock
			pushOperationQueue.errorBlock = errorBlock
		}
	}
	
	private let converter = ObjectToRecordConverter()
	private let pushOperationQueue = PushOperationQueue()
	
	init(parentContext: NSManagedObjectContext, managedObjectModel: NSManagedObjectModel) {
		self.parentContext = parentContext
		self.managedObjectModel = managedObjectModel
        
        super.init()
        
        name = "PushAllLocalDataOperation"
        qualityOfService = .userInitiated
	}
	
	override func main() {
		super.main()
        
		CloudCore.delegate?.willSyncToCloud()
		defer {
			CloudCore.delegate?.didSyncToCloud()
		}
		
		let childContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        childContext.performAndWait {
            childContext.parent = parentContext
            
            var allManagedObjects = Set<NSManagedObject>()
            for entity in managedObjectModel.cloudCoreEnabledEntities {
                guard let entityName = entity.name else { continue }
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                
                do {
                    guard let fetchedObjects = try childContext.fetch(fetchRequest) as? [NSManagedObject] else {
                        continue
                    }
                    
                    allManagedObjects.formUnion(fetchedObjects)
                } catch {
                    errorBlock?(error)
                }
            }
            
            converter.prepareOperationsFor(inserted: allManagedObjects, updated: Set<NSManagedObject>(), deleted: Set<NSManagedObject>())
            let recordsToSave = converter.processPendingOperations(in: childContext).recordsToSave
            pushOperationQueue.addOperations(recordsToSave: recordsToSave, recordIDsToDelete: [RecordIDWithDatabase]())
            pushOperationQueue.waitUntilAllOperationsAreFinished()
            
            do {
                try childContext.save()
            } catch {
                errorBlock?(error)
            }
        }
	}
	
	override func cancel() {
		pushOperationQueue.cancelAllOperations()
		
		super.cancel()
	}

}
