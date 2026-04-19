//
//  ObjectToRecordOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

class ObjectToRecordOperation: Operation, @unchecked Sendable {
	var managedObjectContext: NSManagedObjectContext?
	
	// Set on init
    let scope: CKDatabase.Scope
	let record: CKRecord
	private let changedAttributes: [String]?
	private let serviceAttributeNames: ServiceAttributeNames
	//
	
	var errorCompletionBlock: ((Error) -> Void)?
	var conversionCompletionBlock: ((CKRecord) -> Void)?
	
    init(scope: CKDatabase.Scope, record: CKRecord, changedAttributes: [String]?, serviceAttributeNames: ServiceAttributeNames) {
		self.scope = scope
        self.record = record
		self.changedAttributes = changedAttributes
		self.serviceAttributeNames = serviceAttributeNames
		
		super.init()
		
        name = "ObjectToRecordOperation"
        qualityOfService = .userInteractive
	}
	
	override func main() {
		if self.isCancelled { return }
		guard let context = managedObjectContext else {
			let error = CloudCoreError.coreData("CloudCore framework error")
			errorCompletionBlock?(error)
			return
		}
		
        #if TARGET_OS_IOS
        let app = UIApplication.shared
        var backgroundTaskID = app.beginBackgroundTask(withName: name) {
            app.endBackgroundTask(backgroundTaskID!)
        }
        defer {
            app.endBackgroundTask(backgroundTaskID!)
        }
        #endif
        
        context.performAndWait {
            do {
                try self.fillRecordWithData()
                try context.save()
                self.conversionCompletionBlock?(self.record)
            } catch {
                self.errorCompletionBlock?(error)
            }
        }
	}
	
	private func fillRecordWithData() throws {
		guard let managedObject = try fetchObject(for: record) else {
			throw CloudCoreError.coreData("Unable to find managed object for record: \(record)")
		}
		
		let changedValues = managedObject.committedValues(forKeys: changedAttributes)
		
		for (attributeName, value) in changedValues {
			if serviceAttributeNames.isMaskedUpload(attributeName) { continue }
			
			if let attribute = CoreDataAttribute(value: value, attributeName: attributeName, entity: managedObject.entity) {
				let recordValue = try attribute.makeRecordValue()
                if #available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *) {
                    if attribute.description.allowsCloudEncryption {
                        if let recordValue {
                            record.encryptedValues[attributeName] = (recordValue as! __CKRecordObjCValue)
                        } else {
                            record.encryptedValues[attributeName] =  nil
                        }
                    } else {
                        record.setValue(recordValue, forKey: attributeName)
                    }
                } else {
                    record.setValue(recordValue, forKey: attributeName)
                }
            } else if let relationship = CoreDataRelationship(scope: scope, value: value, relationshipName: attributeName, entity: managedObject.entity) {
				let references = try relationship.makeRecordValue()
				record.setValue(references, forKey: attributeName)
                
                if scope != .public,
                   let parentRef = references as? CKRecord.Reference,
                   parentRef.recordID.zoneID.ownerName == managedObject.sharingOwnerName,
                   let parentAttributeName = managedObject.parentAttributeName,
                   parentAttributeName == attributeName
                {
                    record.setParent(parentRef.recordID)
                }
			}
		}
	}
	
	private func fetchObject(for record: CKRecord) throws -> NSManagedObject? {
		let entityName = record.recordType
		
		let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
		fetchRequest.predicate = NSPredicate(format: serviceAttributeNames.recordName + " == %@", record.recordID.recordName)
		
		return try managedObjectContext?.fetch(fetchRequest).first as? NSManagedObject
	}
}
