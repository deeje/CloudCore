//
//  CloudSaveController.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 06.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

class PushOperationQueue: OperationQueue {
	var errorBlock: ErrorBlock?
	
	/// Modify CloudKit database, operations will be created and added to operation queue.
	func addOperations(recordsToSave: [RecordWithDatabase], recordIDsToDelete: [RecordIDWithDatabase]) {
		var datasource = [DatabaseModifyDataSource]()
		
		// Split records to save to databases
		for recordToSave in recordsToSave {
			if let modifier = datasource.find(database: recordToSave.database) {
				modifier.save.append(recordToSave.record)
			} else {
				let newModifier = DatabaseModifyDataSource(database: recordToSave.database)
				newModifier.save.append(recordToSave.record)
				datasource.append(newModifier)
			}
		}
		
		// Split record ids to delete to databases
		for idToDelete in recordIDsToDelete {
			if let modifier = datasource.find(database: idToDelete.database) {
				modifier.delete.append(idToDelete.recordID)
			} else {
				let newModifier = DatabaseModifyDataSource(database: idToDelete.database)
				newModifier.delete.append(idToDelete.recordID)
				datasource.append(newModifier)
			}
		}
		
		// Perform
		for databaseModifier in datasource {
			addOperation(recordsToSave: databaseModifier.save, recordIDsToDelete: databaseModifier.delete, database: databaseModifier.database)
		}
	}
	
    private func addOperation(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID], database: CKDatabase) {
		// Modify CKRecord Operation
		let modifyRecords = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
        modifyRecords.database = database
		modifyRecords.savePolicy = .changedKeys
        modifyRecords.qualityOfService = .userInitiated
        
		modifyRecords.perRecordCompletionBlock = { record, error in
			if let error = error {
				self.errorBlock?(error)
			} else {
				self.removeCachedAssets(for: record)
			}
		}
		
		modifyRecords.modifyRecordsCompletionBlock = { _, _, error in
			if let error = error {
				self.errorBlock?(error)
			}
		}
                
        let finish = BlockOperation { }
        finish.addDependency(modifyRecords)
        database.add(modifyRecords)
		self.addOperation(finish)
	}
	
	/// Remove locally cached assets prepared for uploading at CloudKit
	private func removeCachedAssets(for record: CKRecord) {
		for key in record.allKeys() {
			guard let asset = record.value(forKey: key) as? CKAsset else { continue }
            if let url = asset.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
		}
	}
    
}

fileprivate class DatabaseModifyDataSource {
	let database: CKDatabase
	var save = [CKRecord]()
    var delete = [CKRecord.ID]()
	
	init(database: CKDatabase) {
		self.database = database
	}
}

extension Sequence where Iterator.Element == DatabaseModifyDataSource {
	func find(database: CKDatabase) -> DatabaseModifyDataSource? {
		for element in self {
			if element.database == database { return element }
		}
		
		return nil
	}
}
