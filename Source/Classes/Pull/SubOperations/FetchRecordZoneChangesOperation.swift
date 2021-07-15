//
//  FetchRecordZoneChangesOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

class FetchRecordZoneChangesOperation: Operation {
	// Set on init
	let tokens: Tokens
	let recordZoneIDs: [CKRecordZone.ID]
	let database: CKDatabase
	//
	
	var errorBlock: ((CKRecordZone.ID, Error) -> Void)?
	var recordChangedBlock: ((CKRecord) -> Void)?
	var recordWithIDWasDeletedBlock: ((CKRecord.ID) -> Void)?
	
    private let optionsByRecordZoneID: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]
	private let fetchQueue = OperationQueue()
	
	init(from database: CKDatabase, recordZoneIDs: [CKRecordZone.ID], tokens: Tokens) {
		self.tokens = tokens
		self.database = database
		self.recordZoneIDs = recordZoneIDs
		
        var optionsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
		for zoneID in recordZoneIDs {
            let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            options.previousServerChangeToken = self.tokens.token(for: zoneID)
			optionsByRecordZoneID[zoneID] = options
		}
		self.optionsByRecordZoneID = optionsByRecordZoneID
		
		super.init()
		
        name = "FetchRecordZoneChangesOperation"
        qualityOfService = .userInteractive
	}
	
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
        
		fetchRecordZoneChanges.recordChangedBlock = {
			self.recordChangedBlock?($0)
		}
		fetchRecordZoneChanges.recordWithIDWasDeletedBlock = { recordID, _ in
			self.recordWithIDWasDeletedBlock?(recordID)
		}
		fetchRecordZoneChanges.recordZoneFetchCompletionBlock = { zoneId, serverChangeToken, clientChangeTokenData, isMore, error in
            self.tokens.setToken(serverChangeToken, for: zoneId)
			
			if let error = error {
				self.errorBlock?(zoneId, error)
			}
			
			if isMore {
				let moreOperation = self.makeFetchOperation(optionsByRecordZoneID: optionsByRecordZoneID)
                let finish = BlockOperation { }
                finish.addDependency(moreOperation)
                self.database.add(moreOperation)
				self.fetchQueue.addOperation(finish)
			}
		}
		
        fetchRecordZoneChanges.database = self.database
        fetchRecordZoneChanges.qualityOfService = .userInteractive

		return fetchRecordZoneChanges
	}
}
