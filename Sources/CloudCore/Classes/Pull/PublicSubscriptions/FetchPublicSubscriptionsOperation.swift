//
//  FetchPublicSubscriptionsOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 14/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

/// Fetch CloudCore's subscriptions from Public CKDatabase

class FetchPublicSubscriptionsOperation: AsynchronousOperation {
    var errorBlock: ErrorBlock?
    var fetchCompletionBlock: (([CKSubscription]) -> Void)?
    
    private let prefix = CloudCore.config.publicSubscriptionIDPrefix
    
    public override init() {
        super.init()
        
        name = "FetchPublicSubscriptionsOperation"
        qualityOfService = .userInitiated
    }
    
    override func main() {
        super.main()
        
        CloudCore.config.container.publicCloudDatabase.fetchAllSubscriptions { (subscriptions, error) in
            defer {
                self.state = .finished
            }
            
            if let error = error {
                self.errorBlock?(error)
                return
            }
            
            guard let subscriptions = subscriptions else {
                self.fetchCompletionBlock?([CKSubscription]())
                return
            }
            
            var cloudCoreSubscriptions = [CKSubscription]()
            for subscription in subscriptions {
                if !subscription.subscriptionID.hasPrefix(self.prefix) { continue }
                cloudCoreSubscriptions.append(subscription)
            }
            
            self.fetchCompletionBlock?(cloudCoreSubscriptions)
        }
    }
}
