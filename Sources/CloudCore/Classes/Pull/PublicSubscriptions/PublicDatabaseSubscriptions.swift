//
//  PublicDatabaseSubscriptions.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

// Use that class to manage subscriptions to public CloudKit database.
// If you want to sync some records with public database you need to subsrcibe for notifications on that changes to enable iCloud -> Local database syncing.
public class PublicDatabaseSubscriptions {
    
    private static var prefix: String { return CloudCore.config.publicSubscriptionIDPrefix }
    
    static var cachedIDs = [String]()
    
    // Create `CKQuerySubscription` for public database, use it if you want to enable syncing public iCloud -> Core Data
    //
    // - Parameters:
    //   - recordType: The string that identifies the type of records to track. You are responsible for naming your app’s record types. This parameter must not be empty string.
    //   - predicate: The matching criteria to apply to the records. This parameter must not be nil. For information about the operators that are supported in search predicates, see the discussion in [CKQuery](apple-reference-documentation://hsDjQFvil9).
    //   - completion: returns subscriptionID and error upon operation completion
    static public func subscribe(recordType: String, predicate: NSPredicate, completion: ((_ subscriptionID: String, _ error: Error?) -> Void)?) {
        let id = prefix + recordType + "-" + predicate.predicateFormat
        if self.cachedIDs.firstIndex(of: id) != nil { return }
        
        let options: CKQuerySubscription.Options = [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        let querySubscription = CKQuerySubscription(recordType: recordType, predicate: predicate, subscriptionID: id, options: options)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        querySubscription.notificationInfo = notificationInfo
        
        let modifySubscriptions = CKModifySubscriptionsOperation(subscriptionsToSave: [querySubscription], subscriptionIDsToDelete: [])
        modifySubscriptions.modifySubscriptionsCompletionBlock = { _, _, error in
            if error == nil {
                self.cachedIDs.append(querySubscription.subscriptionID)
            }

            completion?(querySubscription.subscriptionID, error)
        }
        
        let config = CKOperation.Configuration()
        config.timeoutIntervalForResource = 20
        modifySubscriptions.configuration = config
        
        CloudCore.config.container.publicCloudDatabase.add(modifySubscriptions)
    }
    
    // Unsubscribe from public database
    //
    // - Parameters:
    //   - subscriptionID: id of subscription to remove
    static public func unsubscribe(subscriptionID: String, completion: ((Error?) -> Void)?) {
        let modifySubscription = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: [subscriptionID])
        modifySubscription.modifySubscriptionsCompletionBlock = { _, _, error in
            if error == nil {
                if let index = self.cachedIDs.firstIndex(of: subscriptionID) {
                    self.cachedIDs.remove(at: index)
                }
            }
            
            completion?(error)
        }
        
        let config = CKOperation.Configuration()
        config.timeoutIntervalForResource = 20
        modifySubscription.configuration = config
        
        CloudCore.config.container.publicCloudDatabase.add(modifySubscription)
    }
    
    
    static public func unsubscribe(recordType: String, predicate: NSPredicate, completion: ((Error?) -> Void)?) {
        let id = prefix + recordType + "-" + predicate.predicateFormat
        
        self.unsubscribe(subscriptionID: id, completion: completion)
    }
    
    
    // Refresh local `cachedIDs` variable with actual data from CloudKit.
    // Recommended to use after application's UserDefaults reset.
    //
    // - Parameter completion: called upon operation completion, contains list of CloudCore subscriptions and error
    static public func refreshCache(errorCompletion: ErrorBlock? = nil, successCompletion: (([CKSubscription]) -> Void)? = nil) {
        let operation = FetchPublicSubscriptionsOperation()
        operation.errorBlock = errorCompletion
        operation.fetchCompletionBlock = { subscriptions in
            self.setCache(from: subscriptions)
            successCompletion?(subscriptions)
        }
        operation.start()
    }

    internal static func setCache(from subscriptions: [CKSubscription]) {
        self.cachedIDs = subscriptions.map { $0.subscriptionID }
    }
    
}
