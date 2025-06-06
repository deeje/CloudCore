//
//  CloudCoreSharing.swift
//  CloudCore
//
//  Created by deeje cooley on 5/25/21.
//

import CoreData
import CloudKit

public typealias FetchedEditablePermissionsCompletionBlock = (_ canEdit: Bool) -> Void
public typealias StopSharingCompletionBlock = (_ didStop: Bool) -> Void

public protocol CloudCoreSharing: CloudKitSharing, CloudCoreType {
    
    var isOwnedByCurrentUser: Bool { get }
    var isShared: Bool { get }
    var shareRecordData: Data? { get set }
    
    func fetchExistingShareRecord(completion: @escaping ((CKShare?, Error?) -> Void))
    func fetchShareRecord(in persistentContainer: NSPersistentContainer, completion: @escaping ((CKShare?, Error?) -> Void))
    func fetchEditablePermissions(completion: @escaping FetchedEditablePermissionsCompletionBlock)
    func setShareRecord(share: CKShare?, in persistentContainer: NSPersistentContainer)
    func stopSharing(in persistentContainer: NSPersistentContainer, completion: @escaping StopSharingCompletionBlock)
    
}

extension CloudCoreSharing {
    
    public var isOwnedByCurrentUser: Bool {
        get {
            return ownerName == CKCurrentUserDefaultName
        }
    }
    
    public var isShared: Bool {
        get {
            return shareRecordData != nil
        }
    }
    
    func shareDatabaseAndRecordID(from shareData: Data) -> (CKDatabase, CKRecord.ID) {
        let shareForName = CKShare(archivedData: shareData)!
        let database: CKDatabase
        let shareID: CKRecord.ID
        
        if isOwnedByCurrentUser {
            database = CloudCore.config.container.privateCloudDatabase
            
            shareID = shareForName.recordID
        } else {
            database = CloudCore.config.container.sharedCloudDatabase
            
            let zoneID = CKRecordZone.ID(zoneName: CloudCore.config.zoneName, ownerName: ownerName!)
            shareID = CKRecord.ID(recordName: shareForName.recordID.recordName, zoneID: zoneID)
        }
        
        return (database, shareID)
    }
    
    public func fetchExistingShareRecord(completion: @escaping ((CKShare?, Error?) -> Void)) {
        managedObjectContext?.refresh(self, mergeChanges: true)
        
        if let shareData = shareRecordData {
            let (database, shareID) = shareDatabaseAndRecordID(from: shareData)
            
            let fetchOp = CKFetchRecordsOperation(recordIDs: [shareID])
            fetchOp.qualityOfService = .userInitiated
            fetchOp.perRecordResultBlock = { recordID, result in
                guard recordID == shareID else { return }
                
                switch result {
                case .success(let record):
                    completion(record as? CKShare, nil)
                case .failure(let error):
                    completion(nil, error)
                }
            }
            database.add(fetchOp)
        } else {
            completion(nil, nil)
        }
    }
    
    public func fetchShareRecord(in persistentContainer: NSPersistentContainer, completion: @escaping ((CKShare?, Error?) -> Void)) {
        let aRecord = try! self.restoreRecordWithSystemFields(for: .private)!
        let title = sharingTitle as CKRecordValue?
        let type = sharingType as CKRecordValue?
        
        fetchExistingShareRecord { share, error in
            if let share {
                completion(share, nil)
            } else {
                let newShare = CKShare(rootRecord: aRecord)
                newShare[CKShare.SystemFieldKey.title] = title
                newShare[CKShare.SystemFieldKey.shareType] = type
                
                let modifyOp = CKModifyRecordsOperation(recordsToSave: [aRecord, newShare], recordIDsToDelete: nil)
                modifyOp.savePolicy = .changedKeys
                modifyOp.qualityOfService = .userInitiated
                modifyOp.perRecordSaveBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        if let share = record as? CKShare {
                            self.setShareRecord(share: share, in: persistentContainer)
                            
                            completion(share, nil)
                        }
                    case .failure(let error):
                        completion(nil, error)
                    }
                }
                CloudCore.config.container.privateCloudDatabase.add(modifyOp)
            }
        }
    }
    
    public func fetchEditablePermissions(completion: @escaping FetchedEditablePermissionsCompletionBlock) {
        if isOwnedByCurrentUser {
            completion(true)
        } else {
            fetchExistingShareRecord { record, error in
                var canEdit = false
                
                if let fetchedShare = record {
                    for aParticipant in fetchedShare.participants {
                        if aParticipant.userIdentity.userRecordID?.recordName == CKCurrentUserDefaultName {
                            canEdit = aParticipant.permission == .readWrite
                            break
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    completion(canEdit)
                }
            }
        }
    }
    
    public func setShareRecord(share: CKShare?, in persistentContainer: NSPersistentContainer) {
        persistentContainer.performBackgroundPushTask { moc in
            if let updatedObject = try? moc.existingObject(with: self.objectID) as? CloudCoreSharing {
                updatedObject.shareRecordData = share?.encdodedSystemFields
                try? moc.save()
            }
        }
    }
    
    public func stopSharing(in persistentContainer: NSPersistentContainer, completion: @escaping StopSharingCompletionBlock) {
        if let shareData = shareRecordData {
            let (database, shareID) = shareDatabaseAndRecordID(from: shareData)
            
            database.delete(withRecordID: shareID) { recordID, error in
                completion(error == nil)
            }
            
            if isOwnedByCurrentUser {
                setShareRecord(share: nil, in: persistentContainer)
            }
        } else {
            completion(true)
        }
    }
    
}
