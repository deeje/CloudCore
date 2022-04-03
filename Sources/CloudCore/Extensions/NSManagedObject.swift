//
//  NSManagedObject.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

extension NSManagedObject {
	/// Restore record with system fields if that data is saved in recordData attribute (name of attribute is set through user info)
	///
	/// - Returns: unacrhived `CKRecord` containing restored system fields (like RecordID, tokens, creationg date etc)
	/// - Throws: `CloudCoreError.missingServiceAttributes` if names of CloudCore attributes are not specified in User Info
    public func restoreRecordWithSystemFields(for scope: CKDatabase.Scope) throws -> CKRecord? {
		guard let serviceAttributeNames = self.entity.serviceAttributeNames else {
			throw CloudCoreError.missingServiceAttributes(entityName: self.entity.name)
		}
        let key = scope == .public ? serviceAttributeNames.publicRecordData : serviceAttributeNames.privateRecordData
		guard let encodedRecordData = self.value(forKey: key) as? Data else { return nil }
		
		return CKRecord(archivedData: encodedRecordData)
	}
	
	
	/// Create new CKRecord, write one's encdodedSystemFields and record id to `self`
	/// - Postcondition: `self` is modified (recordData and recordID is written)
	/// - Throws: may throw exception if unable to find attributes marked by User Info as service attributes
	/// - Returns: new `CKRecord`
    @discardableResult func setRecordInformation(for scope: CKDatabase.Scope) throws -> CKRecord {
		guard let entityName = self.entity.name else {
			throw CloudCoreError.coreData("No entity name for \(self.entity)")
		}
		guard let serviceAttributeNames = self.entity.serviceAttributeNames else {
			throw CloudCoreError.missingServiceAttributes(entityName: self.entity.name)
		}
        
        var recordName = self.value(forKey: serviceAttributeNames.recordName) as? String
        if recordName == nil {
            recordName = UUID().uuidString
            self.setValue(recordName, forKey: serviceAttributeNames.recordName)
        }
        
        let aRecord: CKRecord
        if scope == .public {
            let publicRecordID = CKRecord.ID(recordName: recordName!)
            let publicRecord = CKRecord(recordType: entityName, recordID:publicRecordID)
            self.setValue(publicRecord.encdodedSystemFields, forKey: serviceAttributeNames.publicRecordData)
            
            aRecord = publicRecord
        } else {
            let zoneID = CKRecordZone.ID(zoneName: CloudCore.config.zoneName, ownerName: self.sharingOwnerName)
            let privateRecordID = CKRecord.ID(recordName: recordName!, zoneID: zoneID)
            let privateRecord = CKRecord(recordType: entityName, recordID: privateRecordID)
            self.setValue(privateRecord.encdodedSystemFields, forKey: serviceAttributeNames.privateRecordData)
            
            aRecord = privateRecord
        }
        
        let ownerName = self.value(forKey: serviceAttributeNames.ownerName) as? String
        if ownerName == nil {
            self.setValue(aRecord.recordID.zoneID.ownerName, forKey: serviceAttributeNames.ownerName)
        }

		return aRecord
	}
    
    var parentAttributeName: String? {
        get {
            return entity.userInfo?[ServiceAttributeNames.keyParent] as? String
        }
    }
    
    var sharingOwnerName: String {
        get {
            if let parentAttributeName = parentAttributeName,
                let parent: NSManagedObject = value(forKey: parentAttributeName) as? NSManagedObject,
                let serviceAttributes = parent.entity.serviceAttributeNames,
                let parentOwnerName: String = parent.value(forKey: serviceAttributes.ownerName) as? String
            {
                return parentOwnerName
            } else if let serviceAttributes = entity.serviceAttributeNames,
                let ownerName: String = value(forKey: serviceAttributes.ownerName) as? String
            {
                return ownerName
            }
            
            return CKCurrentUserDefaultName
        }
    }
    
}

extension NSManagedObject {
    
    static var updatedPropertyNamesKey = "NSManagedObject_updatedPropertyNamesKey"

    var updatedPropertyNames: [String]? {
        get {
            return objc_getAssociatedObject(self, &NSManagedObject.updatedPropertyNamesKey) as? [String]
        }
        set {
            objc_setAssociatedObject(self, &NSManagedObject.updatedPropertyNamesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

}
