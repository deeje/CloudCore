//
//  NSEntityDescription.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 07.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

extension NSEntityDescription {
	var serviceAttributeNames: ServiceAttributeNames? {
		guard let entityName = self.name else { return nil }
		
		let attributeNamesFromUserInfo = self.parseAttributeNamesFromUserInfo()
		
		// Get required attributes
        // Record Name
        let recordNameAttribute: String
        if let recordNameUserInfoName = attributeNamesFromUserInfo.recordName {
            recordNameAttribute = recordNameUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if self.attributesByName.keys.contains(CloudCore.config.defaultAttributeNameRecordName) {
                recordNameAttribute = CloudCore.config.defaultAttributeNameRecordName
            } else {
                return nil
            }
        }
        
        // Owner Name
        let ownerNameAttribute: String
        if let ownerNameUserInfoName = attributeNamesFromUserInfo.ownerName {
            ownerNameAttribute = ownerNameUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if self.attributesByName.keys.contains(CloudCore.config.defaultAttributeNameOwnerName) {
                ownerNameAttribute = CloudCore.config.defaultAttributeNameOwnerName
            } else {
                return nil
            }
        }
        
        // Private Record Data
        let privateRecordDataAttribute: String
        if let recordDataUserInfoName = attributeNamesFromUserInfo.privateRecordData {
            privateRecordDataAttribute = recordDataUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if self.attributesByName.keys.contains(CloudCore.config.defaultAttributeNamePrivateRecordData) {
                privateRecordDataAttribute = CloudCore.config.defaultAttributeNamePrivateRecordData
            } else {
                return nil
            }
        }
        
        // Public Record Data
        let publicRecordDataAttribute: String
        if let recordDataUserInfoName = attributeNamesFromUserInfo.publicRecordData {
            publicRecordDataAttribute = recordDataUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if self.attributesByName.keys.contains(CloudCore.config.defaultAttributeNamePublicRecordData) {
                publicRecordDataAttribute = CloudCore.config.defaultAttributeNamePublicRecordData
            } else {
                return nil
            }
        }
        
        return ServiceAttributeNames(entityName: entityName,
                                     scopes: attributeNamesFromUserInfo.scopes,
                                     recordName: recordNameAttribute,
                                     ownerName: ownerNameAttribute,
                                     privateRecordData: privateRecordDataAttribute,
                                     publicRecordData: publicRecordDataAttribute)
	}
	
	/// Parse data from User Info dictionary
    private func parseAttributeNamesFromUserInfo() -> (scopes: [CKDatabase.Scope], recordName: String?, ownerName: String?, privateRecordData: String?, publicRecordData: String?) {
        var scopes: [CKDatabase.Scope] = []
        var recordNameAttribute: String?
        var ownerNameAttribute: String?
        var privateRecordDataAttribute: String?
        var publicRecordDataAttribute: String?
        
        func parse(_ attributeName: String, _ userInfo: [AnyHashable: Any]) {
            for (key, value) in userInfo {
                guard let key = key as? String,
                    let value = value as? String else { continue }
                
                if key == ServiceAttributeNames.keyType {
                    switch value {
                    case ServiceAttributeNames.valueRecordName: recordNameAttribute = attributeName
                    case ServiceAttributeNames.valueOwnerName: ownerNameAttribute = attributeName
                    case ServiceAttributeNames.valuePrivateRecordData: privateRecordDataAttribute = attributeName
                    case ServiceAttributeNames.valuePublicRecordData: publicRecordDataAttribute = attributeName
                    default: continue
                    }
                } else if key == ServiceAttributeNames.keyScopes {
                    let scopeStrings = value.components(separatedBy: ",")
                    for scopeString in scopeStrings {
                        switch scopeString {
                        case "public":
                            scopes.append(.public)
                        case "private":
                            scopes.append(.private)
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        if let userInfo = self.userInfo {
            parse("", userInfo)
        }
        
		// In attribute
		for (attributeName, attributeDescription) in self.attributesByName {
			guard let userInfo = attributeDescription.userInfo else { continue }
			parse(attributeName, userInfo)
		}
		
		return (scopes, recordNameAttribute, ownerNameAttribute, privateRecordDataAttribute, publicRecordDataAttribute)
	}
	
}
