//
//  SubscribeOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 12/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CloudKit

class SubscribeOperation: AsynchronousOperation {
	
	var errorBlock: ErrorBlock?
	
	private let queue = OperationQueue()
    
    public override init() {
        super.init()
        
        name = "SubscribeOperation"
        qualityOfService = .userInitiated
    }
    
	override func main() {
		super.main()

		let container = CloudCore.config.container
		
		let subcribeToPrivate = self.makeRecordZoneSubscriptionOperation(for: container.privateCloudDatabase, id: CloudCore.config.subscriptionIDForPrivateDB)
		let fetchPrivateSubscription = makeFetchSubscriptionOperation(for: container.privateCloudDatabase,
																	   searchForSubscriptionID: CloudCore.config.subscriptionIDForPrivateDB,
																	   operationToCancelIfSubcriptionExists: subcribeToPrivate)
		subcribeToPrivate.addDependency(fetchPrivateSubscription)
		
        let subscribeToShared = self.makeRecordZoneSubscriptionOperation(for: container.sharedCloudDatabase, id: CloudCore.config.subscriptionIDForSharedDB)
        let fetchSharedSubscription = makeFetchSubscriptionOperation(for: container.sharedCloudDatabase,
                                                                       searchForSubscriptionID: CloudCore.config.subscriptionIDForSharedDB,
                                                                       operationToCancelIfSubcriptionExists: subscribeToShared)
        subscribeToShared.addDependency(fetchSharedSubscription)
        
		// Finish operation
		let finishOperation = BlockOperation {
			self.state = .finished
		}
        finishOperation.addDependency(subcribeToPrivate)
        finishOperation.addDependency(fetchPrivateSubscription)
        finishOperation.addDependency(subscribeToShared)
        finishOperation.addDependency(fetchSharedSubscription)

        subcribeToPrivate.database?.add(subcribeToPrivate)
        fetchPrivateSubscription.database?.add(fetchPrivateSubscription)
        subscribeToShared.database?.add(subscribeToShared)
        fetchSharedSubscription.database?.add(fetchSharedSubscription)
        
		queue.addOperation(finishOperation)
	}
	
	private func makeRecordZoneSubscriptionOperation(for database: CKDatabase, id: String) -> CKModifySubscriptionsOperation {
        let notificationInfo = CKSubscription.NotificationInfo()
		notificationInfo.shouldSendContentAvailable = true
		
        let subscription = (database == CloudCore.config.container.sharedCloudDatabase) ? CKDatabaseSubscription(subscriptionID: id) :
            CKRecordZoneSubscription(zoneID: CloudCore.config.privateZoneID(), subscriptionID: id)
        subscription.notificationInfo = notificationInfo

		let modifySubscriptions = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        modifySubscriptions.database = database
		modifySubscriptions.modifySubscriptionsCompletionBlock = {
			if let error = $2 {
				// Cancellation is not an error
				if case CKError.operationCancelled = error { return }
				
				self.errorBlock?(error)
			}
		}
		
        modifySubscriptions.qualityOfService = .userInitiated
		
		return modifySubscriptions
	}
	
	private func makeFetchSubscriptionOperation(for database: CKDatabase, searchForSubscriptionID subscriptionID: String, operationToCancelIfSubcriptionExists operationToCancel: CKModifySubscriptionsOperation) -> CKFetchSubscriptionsOperation {
		let fetchSubscriptions = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])
		fetchSubscriptions.database = database
		fetchSubscriptions.fetchSubscriptionCompletionBlock = { subscriptions, error in
			// If no errors = subscription is found and we don't need to subscribe again
			if error == nil {
				operationToCancel.cancel()
			}
		}
        fetchSubscriptions.qualityOfService = .userInitiated
        
		return fetchSubscriptions
	}
	
}
