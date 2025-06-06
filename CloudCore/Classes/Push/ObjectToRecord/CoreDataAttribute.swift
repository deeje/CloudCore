//
//  CoreDataAttribute.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

class CoreDataAttribute {
	typealias Class = CoreDataAttribute
	
	let name: String
	let value: Any?
	let description: NSAttributeDescription

	/// Initialize Core Data Attribute with properties and value
	/// - Returns: `nil` if it is not an attribute (possible it is relationship?)
	init?(value: Any?, attributeName: String, entity: NSEntityDescription) {
		guard let description = CoreDataAttribute.attributeDescription(for: attributeName, in: entity) else {
			// it is not an attribute
			return nil
		}
        
        self.description = description
		
		if value is NSNull {
			self.value = nil
        } else if let attribute = entity.attributesByName[attributeName],
            attribute.attributeType == .transformableAttributeType {
            if let transformerName = attribute.valueTransformerName,
                let transformer = ValueTransformer(forName: NSValueTransformerName(rawValue: transformerName)) {
                self.value = transformer.reverseTransformedValue(value)
            } else {
                self.value = try? NSKeyedArchiver.archivedData(withRootObject: value!, requiringSecureCoding: false)
            }
        } else {
            self.value = value
        }

		self.name = attributeName
	}
	
	private static func attributeDescription(for lookupName: String, in entity: NSEntityDescription) -> NSAttributeDescription? {
		for (name, description) in entity.attributesByName {
			if lookupName == name { return description }
		}
		
		return nil
	}
	
	/// Return value in CloudKit-friendly format that is usable in CKRecord
	/// - note: Possible long operation (if attribute has binary data asset maybe created)
	func makeRecordValue() throws -> Any? {
		switch self.description.attributeType {
		case .binaryDataAttributeType:
			guard let binaryData = self.value as? Data else {
				return nil
			}
			
			if binaryData.count > 1024*1024 || description.allowsExternalBinaryDataStorage {
				return try Class.createAsset(for: binaryData)
			} else {
				return binaryData
			}
		default: return self.value
		}
	}

	static func createAsset(for data: Data) throws -> CKAsset {
		let fileName = UUID().uuidString.lowercased() + ".bin"
		let fullURL = URL(fileURLWithPath: fileName, relativeTo: FileManager.default.temporaryDirectory)

		try data.write(to: fullURL)
		return CKAsset(fileURL: fullURL)
	}
}
