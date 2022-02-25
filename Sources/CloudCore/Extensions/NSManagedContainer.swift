//
//  NSManagedObjectContext.swift
//  CloudCore
//
//  Created by deeje cooley on 5/11/21.
//

import CoreData

extension NSPersistentContainer {
    
    public func performBackgroundPushTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        performBackgroundTask { moc in
            moc.name = CloudCore.config.pushContextName
            moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            block(moc)
        }
    }
    
}
