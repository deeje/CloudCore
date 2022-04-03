//
//  CloudCoreError.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CoreData

/// A enumeration representing an error value that can be thrown by framework
public enum CloudCoreError: Error, CustomStringConvertible {
	/// Entity doesn't have some required attributes
	case missingServiceAttributes(entityName: String?)
	
	/// Some CloudKit error
	case cloudKit(String)
	
	/// Some CoreData error
	case coreData(String)
	
	/// Custom error, description is placed inside associated value
	case custom(String)
	
	
	/// CloudCore doesn't support relationships with `NSOrderedSet` type
	case orderedSetRelationshipIsNotSupported(NSRelationshipDescription)

	/// A textual representation of error
	public var localizedDescription: String {
		switch self {
		case .missingServiceAttributes(let entity):
			let entityName = entity ?? "UNKNOWN_ENTITY"
			return entityName + " doesn't contain all required services attributes"
		case .cloudKit(let text): return "iCloud error: \(text)"
		case .coreData(let text): return "Core Data error: \(text)"
		case .custom(let error): return error
		case .orderedSetRelationshipIsNotSupported(let relationship): return "Relationships with NSOrderedSet type are not supported. Error occured in: \(relationship)"
		}
	}
	
	/// A textual representation of error
	public var description: String { return self.localizedDescription }
}

public typealias ErrorBlock = (Error) -> Void
