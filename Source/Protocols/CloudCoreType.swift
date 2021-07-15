//
//  CloudCoreType.swift
//  CloudCore
//
//  Created by deeje cooley on 5/25/21.
//

import CoreData

/// thinking of a typesafe way to identify the required fields

public protocol CloudCoreType where Self: NSManagedObject {
    
    var recordName: String? { get }
    var ownerName: String? { get }
    var publicRecordData: Data? { get }
    var privateRecordData: Data? { get set }
    
}

