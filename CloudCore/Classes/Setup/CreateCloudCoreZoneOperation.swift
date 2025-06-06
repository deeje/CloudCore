//
//  CreateCloudCoreZoneOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 12/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CloudKit

class CreateCloudCoreZoneOperation: AsynchronousOperation, @unchecked Sendable {
	
	var errorBlock: ErrorBlock?
	private var createZoneOperation: CKModifyRecordZonesOperation?
	
    public override init() {
        super.init()
        
        name = "CreateCloudCoreZoneOperation"
        qualityOfService = .userInitiated
    }
    
	override func main() {
		super.main()

		let cloudCoreZone = CKRecordZone(zoneName: CloudCore.config.zoneName)
		let recordZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [cloudCoreZone], recordZoneIDsToDelete: nil)
        recordZoneOperation.qualityOfService = .userInitiated
        recordZoneOperation.perRecordZoneSaveBlock = { recordZone, error in
            if case let .failure(error) = error {
                print("CreateCloudCoreZoneOperation.perRecordZoneSave error: \(error)")
            }
        }
        recordZoneOperation.modifyRecordZonesResultBlock = { result in
            if case let .failure(error) = result {
                self.errorBlock?(error)
            }
            
            self.state = .finished
        }
        
		
		CloudCore.config.container.privateCloudDatabase.add(recordZoneOperation)
		self.createZoneOperation = recordZoneOperation
	}
	
}
