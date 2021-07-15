//
//  CloudKitSharing.swift
//  CloudCore
//
//  Created by deeje cooley on 5/25/21.
//

import CoreData

public protocol CloudKitSharing where Self: NSManagedObject {
    
    var sharingTitle: String? { get }
    var sharingType: String? { get }
    var sharingImage: Data? { get }
    
}
