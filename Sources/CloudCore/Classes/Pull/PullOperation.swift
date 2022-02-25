//
//  PullOperation.swift
//  CloudCore
//
//  Created by deeje cooley on 3/23/21.
//

import CloudKit
import CoreData

public class PullOperation: Operation {
    
    internal let persistentContainer: NSPersistentContainer
    
    /// Called every time if error occurs
    public var errorBlock: ErrorBlock?
    
    internal let queue = OperationQueue()
    
    internal var objectsWithMissingReferences = [MissingReferences]()
    
    public init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
        
        super.init()
        
        qualityOfService = .userInitiated
        
        queue.name = "PullQueue"
        queue.maxConcurrentOperationCount = 1
    }
    
    internal func addConvertRecordOperation(record: CKRecord, context: NSManagedObjectContext) {
        // Convert and write CKRecord To NSManagedObject Operation
        let convertOperation = RecordToCoreDataOperation(parentContext: context, record: record)
        convertOperation.errorBlock = { self.errorBlock?($0) }
        convertOperation.completionBlock = {
            context.performAndWait {
                self.objectsWithMissingReferences.append(convertOperation.missingObjectsPerEntities)
            }
        }
        self.queue.addOperation(convertOperation)
    }
    
    internal func processMissingReferences(context: NSManagedObjectContext) {
        // iterate over all missing references and fix them, now are all NSManagedObjects created
        context.performAndWait {
            for missingReferences in objectsWithMissingReferences {
                for (object, references) in missingReferences {
                    guard let serviceAttributes = object.entity.serviceAttributeNames else { continue }
                    
                    for (attributeName, recordNames) in references {
                        for recordName in recordNames {
                            guard let relationship = object.entity.relationshipsByName[attributeName], let targetEntityName = relationship.destinationEntity?.name else { continue }
                            
                            // TODO: move to extension
                            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: targetEntityName)
                            fetchRequest.predicate = NSPredicate(format: serviceAttributes.recordName + " == %@" , recordName)
                            fetchRequest.fetchLimit = 1
                            fetchRequest.includesPropertyValues = false
                            
                            do {
                                let foundObject = try context.fetch(fetchRequest).first as? NSManagedObject
                                
                                if let foundObject = foundObject {
                                    if relationship.isToMany {
                                        let set = object.value(forKey: attributeName) as? NSMutableSet ?? NSMutableSet()
                                        set.add(foundObject)
                                        object.setValue(set, forKey: attributeName)
                                    } else {
                                        object.setValue(foundObject, forKey: attributeName)
                                    }
                                } else {
                                    print("warning: object not found " + recordName)
                                }
                            } catch {
                                self.errorBlock?(error)
                            }
                        }
                    }
                }
            }
        }
    }
    
}
