//
//  DeleteSubscriptionOperation.swift
//  CloudCore
//
//  Created by Sergey Bolshedvorsky on 04/01/2019.
//  Copyright © 2019 Sergey Bolshedvorsky. All rights reserved.
//

import Foundation
import CloudKit

#if !os(watchOS)
@available(watchOS, unavailable)
class DeleteSubscriptionOperation: AsynchronousOperation {

    var errorBlock: ErrorBlock?

    private let queue = OperationQueue()

    override func main() {
        super.main()

        let container = CloudCore.config.container

        let deletePrivateSubscription = self.makeRecordZoneDeleteSubscriptionOperation(for: container.privateCloudDatabase, id: CloudCore.config.subscriptionIDForPrivateDB)

        let deleteSharedSubscription = self.makeRecordZoneDeleteSubscriptionOperation(for: container.sharedCloudDatabase, id: CloudCore.config.subscriptionIDForSharedDB)

        // Finish operation
        let finishOperation = BlockOperation {
            self.state = .finished
        }
        finishOperation.addDependency(deletePrivateSubscription)
        finishOperation.addDependency(deleteSharedSubscription)

        queue.addOperations([deletePrivateSubscription,
                             deleteSharedSubscription,
                             finishOperation], waitUntilFinished: false)
    }

    private func makeRecordZoneDeleteSubscriptionOperation(for database: CKDatabase, id: String) -> CKModifySubscriptionsOperation {

        let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: [id])
        operation.modifySubscriptionsCompletionBlock = {
            if let error = $2 {
                // Cancellation is not an error
                if case CKError.operationCancelled = error { return }

                self.errorBlock?(error)
            }
        }

        operation.database = database

        return operation
    }

}
#endif
