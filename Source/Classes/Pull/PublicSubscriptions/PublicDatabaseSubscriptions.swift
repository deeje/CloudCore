//
//  PublicDatabaseSubscriptions.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData
import UIKit

private let lastSyncDatesKey = "lastSyncDates"

// Use that class to manage subscriptions to public CloudKit database.
// If you want to sync some records with public database you need to subsrcibe for notifications on that changes to enable iCloud -> Local database syncing.
public class PublicDatabaseSubscriptions {
    
    private static var prefix: String { return CloudCore.config.publicSubscriptionIDPrefix }
    
    static var subscriptions: [CKSubscription] = []
    
    static var subscriptionIDs = { subscriptions.map { $0.subscriptionID }} ()
    
    private static let pullQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    
    
    private static func lastSync(for subscriptionID: String) -> NSDate? {
        var lastDates: [String: NSDate]? = UserDefaults.standard.object(forKey: lastSyncDatesKey) as? Dictionary
        
        return lastDates?[subscriptionID]
    }
    
    private static func setLastSync(for subscriptionID: String, date: NSDate?) {
        var lastDates: [String: NSDate]? = UserDefaults.standard.object(forKey: lastSyncDatesKey) as? Dictionary
        if lastDates == nil {
            lastDates = [:]
        }
        lastDates![subscriptionID] = date
        UserDefaults.standard.set(lastDates, forKey: lastSyncDatesKey)
    }
    
    // Create `CKQuerySubscription` for public database, use it if you want to enable syncing public iCloud -> Core Data
    //
    // - Parameters:
    //   - recordType: The string that identifies the type of records to track. You are responsible for naming your app’s record types. This parameter must not be empty string.
    //   - predicate: The matching criteria to apply to the records. This parameter must not be nil. For information about the operators that are supported in search predicates, see the discussion in [CKQuery](apple-reference-documentation://hsDjQFvil9).
    //   - completion: returns subscriptionID and error upon operation completion
    static public func subscribe(recordType: String, predicate: NSPredicate, completion: ((_ subscription: CKSubscription, _ error: Error?) -> Void)?) {
        let newSubscriptionID = prefix + recordType + "-" + predicate.predicateFormat
        
            // if we are already subscribed, return
        if subscriptionIDs.firstIndex(of: newSubscriptionID) != nil { return }
        
        let options: CKQuerySubscription.Options = [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        let querySubscription = CKQuerySubscription(recordType: recordType, predicate: predicate, subscriptionID: newSubscriptionID, options: options)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        querySubscription.notificationInfo = notificationInfo
        
        let modifySubscriptions = CKModifySubscriptionsOperation(subscriptionsToSave: [querySubscription], subscriptionIDsToDelete: [])
        modifySubscriptions.modifySubscriptionsResultBlock = { result in
            switch result {
            case .success():
                self.subscriptions.append(querySubscription)
                completion?(querySubscription, nil)
            case .failure(let error):
                completion?(querySubscription, error)
            }
        }
        
        let config = CKOperation.Configuration()
        config.timeoutIntervalForResource = 20
        config.qualityOfService = .userInitiated
        modifySubscriptions.configuration = config
        
        CloudCore.config.container.publicCloudDatabase.add(modifySubscriptions)
    }
    
    // Unsubscribe from public database
    //
    // - Parameters:
    //   - subscriptionID: id of subscription to remove
    static public func unsubscribe(subscriptionID: String, completion: ((Error?) -> Void)?) {
        let modifySubscription = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: [subscriptionID])
        modifySubscription.modifySubscriptionsResultBlock = { result in
            switch result {
            case .success():
                if let index = self.subscriptionIDs.firstIndex(of: subscriptionID) {
                    self.subscriptions.remove(at: index)
                }
                completion?(nil)
            case .failure(let error):
                completion?(error)
            }
        }
        
        let config = CKOperation.Configuration()
        config.timeoutIntervalForResource = 20
        config.qualityOfService = .userInitiated
        modifySubscription.configuration = config
        
        CloudCore.config.container.publicCloudDatabase.add(modifySubscription)
    }
    
    
    static public func unsubscribe(recordType: String, predicate: NSPredicate, completion: ((Error?) -> Void)?) {
        let oldSubscriptionID = prefix + recordType + "-" + predicate.predicateFormat
        
        self.unsubscribe(subscriptionID: oldSubscriptionID, completion: completion)
    }
    
    
    // Refresh local `cachedIDs` variable with actual data from CloudKit.
    // Recommended to use after application's UserDefaults reset.
    //
    // - Parameter completion: called upon operation completion, contains list of CloudCore subscriptions and error
    static public func fetchSubscriptions(errorCompletion: ErrorBlock? = nil, successCompletion: (([CKSubscription]) -> Void)? = nil) {
        let operation = FetchPublicSubscriptionsOperation()
        operation.errorBlock = errorCompletion
        operation.fetchCompletionBlock = { subscriptions in
            self.subscriptions = subscriptions
            
            successCompletion?(subscriptions)
        }
        pullQueue.addOperation(operation)
    }
    
    static func pullPublic(_ querySubscription: CKQuerySubscription, into persistentContainer: NSPersistentContainer) {
        let publicDatabase = CloudCore.config.container.publicCloudDatabase
        let subscriptionID = querySubscription.subscriptionID
        let entityType = querySubscription.recordType!
        var predicate = querySubscription.predicate
        
        let modDateField = "modificationDate"
        
        if let date = PublicDatabaseSubscriptions.lastSync(for: subscriptionID) {
            let datePredicate = NSPredicate(format: "%K > %@", modDateField, date)
            
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, datePredicate])
        }
                
        let query = CKQuery(recordType: entityType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: modDateField, ascending: true)]
        let queryOp = CKQueryOperation(query: query)
        queryOp.desiredKeys = [modDateField]
        queryOp.qualityOfService = .userInitiated
        queryOp.recordMatchedBlock = { recordID, result in
            if case .success(let record) = result {
                let pullOp = PullRecordOperation(rootRecordID: recordID, database: publicDatabase, persistentContainer: persistentContainer)
                pullQueue.addOperation(pullOp)
                
                pullOp.completionBlock = {
                    PublicDatabaseSubscriptions.setLastSync(for: subscriptionID, date: record.modificationDate as? NSDate)
                }
            }
        }
        queryOp.queryResultBlock = { result in
            switch result {
            case .success(let cursor):
                if cursor != nil {
                    PublicDatabaseSubscriptions.pullPublic(querySubscription, into: persistentContainer)
                }
                break
            case .failure(let error):
                print("\(subscriptionID) error == \(error)")
            }
        }
        publicDatabase.add(queryOp)
    }
    
    static public func pull(into persistentContainer: NSPersistentContainer) {
        for subscription in subscriptions {
            guard let querySubscription = subscription as? CKQuerySubscription else { continue }
            
            pullPublic(querySubscription, into: persistentContainer)
        }
    }
    
}
