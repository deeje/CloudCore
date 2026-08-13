//
//  FetchRecordZoneChangesOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

#if os(iOS)
import UIKit
#endif

class FetchRecordZoneChangesOperation: Operation, @unchecked Sendable {
	// Set on init
	let tokens: Tokens
	let recordZoneIDs: [CKRecordZone.ID]
	let database: CKDatabase
	//
	
	var errorBlock: ((CKRecordZone.ID, Error) -> Void)?
	var recordChangedBlock: ((CKRecord) -> Void)?
	var recordWithIDWasDeletedBlock: ((CKRecord.ID) -> Void)?
    var tokenUpdatedBlock: (() -> Void)?
	
    private let optionsByRecordZoneID: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]
	private let fetchQueue = OperationQueue()
	
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier?
    #endif
    
    init(from database: CKDatabase, recordZoneIDs: [CKRecordZone.ID], tokens: Tokens, desiredKeys: [String]? = nil) {
		self.tokens = tokens
		self.database = database
		self.recordZoneIDs = recordZoneIDs
		
        var optionsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
		for zoneID in recordZoneIDs {
            let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            options.previousServerChangeToken = self.tokens.token(for: zoneID)
			optionsByRecordZoneID[zoneID] = options
            options.desiredKeys = desiredKeys
		}
		self.optionsByRecordZoneID = optionsByRecordZoneID
		
		super.init()
		
        name = "FetchRecordZoneChangesOperation"
        qualityOfService = .userInitiated
	}
	
	override func main() {
		super.main()
        
		let fetchOperation = self.makeFetchOperation(optionsByRecordZoneID: optionsByRecordZoneID)
        let finish = BlockOperation { }
        finish.addDependency(fetchOperation)
        database.add(fetchOperation)
		fetchQueue.addOperation(finish)
		
		fetchQueue.waitUntilAllOperationsAreFinished()
	}
	
    private func makeFetchOperation(optionsByRecordZoneID: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]) -> CKFetchRecordZoneChangesOperation {
		// Init Fetch Operation
		let fetchRecordZoneChanges = CKFetchRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, configurationsByRecordZoneID: optionsByRecordZoneID)
        
        fetchRecordZoneChanges.recordWasChangedBlock = { recordID, result in
            if case let .success(record) = result {
                self.recordChangedBlock?(record)
            }
            else if case let .failure(error) = result {
                print("fetchRecordZoneChanges.recordWasChanged error: \(error)")
            }
        }
		fetchRecordZoneChanges.recordWithIDWasDeletedBlock = { recordID, _ in
			self.recordWithIDWasDeletedBlock?(recordID)
		}
        fetchRecordZoneChanges.recordZoneChangeTokensUpdatedBlock = { zoneId, serverChangeToken, _ in
            self.tokenUpdatedBlock?()
            
            self.tokens.setToken(serverChangeToken, for: zoneId)
        }
        fetchRecordZoneChanges.recordZoneFetchResultBlock = { zoneId, result in
            switch result {
            case .success(let (serverChangeToken, _, moreComing)):
                self.tokens.setToken(serverChangeToken, for: zoneId)
                if moreComing {
                    let moreOperation = self.makeFetchOperation(optionsByRecordZoneID: optionsByRecordZoneID)
                    let finish = BlockOperation { }
                    finish.addDependency(moreOperation)
                    self.database.add(moreOperation)
                    self.fetchQueue.addOperation(finish)
                }
            case .failure(let error):
                print("fetchRecordZoneChanges.recordZoneFetchResult error: \(error)")
                self.errorBlock?(zoneId, error)
            }
        }
        fetchRecordZoneChanges.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                print("fetchRecordZoneChanges.fetchRecordZoneChangesResult error: \(error)")
            }
        }
		
        fetchRecordZoneChanges.database = self.database
        fetchRecordZoneChanges.qualityOfService = .userInitiated

		return fetchRecordZoneChanges
	}
}
