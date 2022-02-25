//
//  SetupOperation.swift
//  CloudCore-iOS
//
//  Created by Vasily Ulianov on 13/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CoreData

/**
	Performs several setup operations:

	1. Create CloudCore Zone.
	2. Subscribe to that zone.
	3. Upload all local data to cloud.
*/
class SetupOperation: Operation {
	
	var errorBlock: ErrorBlock?
	let container: NSPersistentContainer
    let uploadAllData: Bool
	
	/// - Parameters:
	///   - container: persistent container to get managedObject model from
	///   - parentContext: context where changed data will be save (recordID's). If it is `nil`, new context will be created from `container` and saved
    init(container: NSPersistentContainer, uploadAllData: Bool) {
		self.container = container
        self.uploadAllData = uploadAllData
        
        super.init()
        
        name = "SetupOperation"
        qualityOfService = .userInitiated
	}
	
	private let queue = OperationQueue()
	
	override func main() {
		super.main()
		
        #if TARGET_OS_IOS
        let app = UIApplication.shared
        var backgroundTaskID = app.beginBackgroundTask(withName: name) {
            app.endBackgroundTask(backgroundTaskID!)
        }
        defer {
            app.endBackgroundTask(backgroundTaskID!)
        }
        #endif
        
		let childContext = container.newBackgroundContext()
        var operations: [Operation] = []
        
		// Create CloudCore Zone
		let createZoneOperation = CreateCloudCoreZoneOperation()
		createZoneOperation.errorBlock = {
			self.errorBlock?($0)
			self.queue.cancelAllOperations()
		}
		operations.append(createZoneOperation)
        
		// Subscribe operation
		let subscribeOperation = SubscribeOperation()
		subscribeOperation.errorBlock = errorBlock
		subscribeOperation.addDependency(createZoneOperation)
		operations.append(subscribeOperation)
        
        if uploadAllData {
            // Upload all local data
            let uploadOperation = PushAllLocalDataOperation(parentContext: childContext, managedObjectModel: container.managedObjectModel)
            uploadOperation.errorBlock = errorBlock
            
            uploadOperation.addDependency(subscribeOperation)
            operations.append(uploadOperation)
        }
        
        queue.maxConcurrentOperationCount = 1
		queue.addOperations(operations, waitUntilFinished: true)
		
        childContext.performAndWait {
            do {
                // It's safe to save because we instatinated that context in current thread
                try childContext.save()
            } catch {
                errorBlock?(error)
            }
        }
	}
	
}
