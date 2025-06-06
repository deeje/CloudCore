//
//  ObjectToRecordConverter.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

class ObjectToRecordConverter {
	enum ManagedObjectChangeType {
		case inserted, updated
	}
	
	var errorBlock: ErrorBlock?
	
	private var pendingConvertOperations = [ObjectToRecordOperation]()
	private let operationQueue = OperationQueue()
	
	private var convertedRecords = [RecordWithDatabase]()
	private var recordIDsToDelete = [RecordIDWithDatabase]()
	
    var hasPendingOperations: Bool {
        return !pendingConvertOperations.isEmpty || !recordIDsToDelete.isEmpty
    }
    
	func prepareOperationsFor(inserted: Set<NSManagedObject>, updated: Set<NSManagedObject>, deleted: Set<NSManagedObject>) {        
        prepareOperationsFor(inserted: inserted, updated: updated, deleted: convert(deleted: deleted))
	}
    
    func prepareOperationsFor(inserted: Set<NSManagedObject>, updated: Set<NSManagedObject>, deleted deletedIDs: [RecordIDWithDatabase]) {
        pendingConvertOperations = convertOperations(from: inserted, changeType: .inserted)
        pendingConvertOperations += convertOperations(from: updated, changeType: .updated)
        
        recordIDsToDelete = deletedIDs
    }
	
	private func convertOperations(from objectSet: Set<NSManagedObject>, changeType: ManagedObjectChangeType) -> [ObjectToRecordOperation] {
		var operations = [ObjectToRecordOperation]()
		
		for object in objectSet {
			// Ignore entities that doesn't have required service attributes
			guard let serviceAttributeNames = object.entity.serviceAttributeNames else { continue }

            for scope in serviceAttributeNames.scopes {
                do {
                    let recordWithSystemFields: CKRecord
                    
                    if let restoredRecord = try object.restoreRecordWithSystemFields(for: scope) {
                        switch changeType {
                        case .inserted:
                            // Create record with same ID but wihout token data (that record was accidently deleted from CloudKit perhaps, recordID exists in CoreData, but record doesn't exist in CloudKit
                            let recordID = restoredRecord.recordID
                            recordWithSystemFields = CKRecord(recordType: restoredRecord.recordType, recordID: recordID)
                        case .updated:
                            recordWithSystemFields = restoredRecord
                        }
                    } else {
                        recordWithSystemFields = try object.setRecordInformation(for: scope)
                    }
                    
                    var changedAttributes: [String]?
                    
                    // Save changes keys only for updated object, for inserted objects full sync will be used
                    if case .updated = changeType {
                        changedAttributes = Array(object.changedValues().keys)
                        
                        if changedAttributes?.count == 0 {
                            changedAttributes = object.updatedPropertyNames
                        }
                    }
                    
                    let convertOperation = ObjectToRecordOperation(scope: scope,
                                                                   record: recordWithSystemFields,
                                                                   changedAttributes: changedAttributes,
                                                                   serviceAttributeNames: serviceAttributeNames)
                    
                    convertOperation.errorCompletionBlock = { [weak self] error in
                        self?.errorBlock?(error)
                    }
                    
                    let targetScope = targetScope(for: scope, and: object)
                    let cloudDatabase = database(for: targetScope)
                    convertOperation.conversionCompletionBlock = { [weak self] record in
                        guard let me = self else { return }
                        
                        let recordWithDB = RecordWithDatabase(record, cloudDatabase)
                        me.convertedRecords.append(recordWithDB)
                    }
                    
                    operations.append(convertOperation)
                } catch {
                    errorBlock?(error)
                }
            }
		}
		
		return operations
	}
	
	private func convert(deleted objectSet: Set<NSManagedObject>) -> [RecordIDWithDatabase] {
		var recordIDs = [RecordIDWithDatabase]()
		
		for object in objectSet {
            guard let serviceAttributeNames = object.entity.serviceAttributeNames else { continue }
            
            for scope in serviceAttributeNames.scopes {
                if let restoredRecord = try? object.restoreRecordWithSystemFields(for: scope) {
                    let targetScope = self.targetScope(for: scope, and: object)
                    let database = self.database(for: targetScope)
                    let recordIDWithDB = RecordIDWithDatabase(restoredRecord.recordID, database)
                    recordIDs.append(recordIDWithDB)
                }
            }
		}
		
		return recordIDs
	}
	
	/// Add all unconfirmed operations to operation queue
	/// - attention: Don't call this method from same context's `perfom`, that will cause deadlock
	func processPendingOperations(in context: NSManagedObjectContext) -> (recordsToSave: [RecordWithDatabase], recordIDsToDelete: [RecordIDWithDatabase]) {
		for operation in pendingConvertOperations {
			operation.managedObjectContext = context
			operationQueue.addOperation(operation)
		}
        
		pendingConvertOperations = [ObjectToRecordOperation]()
        
		operationQueue.waitUntilAllOperationsAreFinished()
        
		let recordsToSave = self.convertedRecords
		let recordIDsToDelete = self.recordIDsToDelete
		
		self.convertedRecords = [RecordWithDatabase]()
		self.recordIDsToDelete = [RecordIDWithDatabase]()
		
		return (recordsToSave, recordIDsToDelete)
	}
	
	/// Get appropriate database for modify operations
    private func database(for scope: CKDatabase.Scope) -> CKDatabase {
        return CloudCore.config.container.database(with: scope)
	}
    
    private func targetScope(for scope: CKDatabase.Scope, and object: NSManagedObject) -> CKDatabase.Scope {
        var target = scope
        if scope == .private
        {
            if object.sharingOwnerName != CKCurrentUserDefaultName {
                target = .shared
            }
        }
        
        return target
    }
}
