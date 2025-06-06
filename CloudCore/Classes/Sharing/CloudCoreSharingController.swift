//
//  CloudCoreSharingController.swift
//  CloudCore
//
//  Created by deeje cooley on 5/25/21.
//

#if os(iOS)

import UIKit
import CoreData
import CloudKit

public typealias ConfigureSharingCompletionBlock = (_ sharingController: UICloudSharingController?) -> Void

public class CloudCoreSharingController: NSObject, UICloudSharingControllerDelegate {
    
    let persistentContainer: NSPersistentContainer
    let object: CloudCoreSharing
    
    public var didSaveShare: ((CKShare)->Void)?
    public var didStopSharing: (()->Void)?
    public var didError: ((Error)->Void)?
    
    public init(persistentContainer: NSPersistentContainer, object: CloudCoreSharing) {
        self.persistentContainer = persistentContainer
        self.object = object
    }
    
    public func createSharingController(share: CKShare,
                                        permissions: UICloudSharingController.PermissionOptions,
                                        container: CKContainer) -> UICloudSharingController
    {
        let sharingController = UICloudSharingController(share: share, container: CloudCore.config.container)
        sharingController.availablePermissions = permissions
        sharingController.delegate = self
        
        return sharingController
    }
    
    public func configureSharingController(permissions: UICloudSharingController.PermissionOptions,
                                           completion: @escaping ConfigureSharingCompletionBlock) {
        object.fetchShareRecord(in: persistentContainer) { [weak self] share, error in
            guard let self, error == nil, let share = share else { completion(nil); return }
            
            DispatchQueue.main.async {
                let sharingController = self.createSharingController(share: share, permissions: permissions, container: CloudCore.config.container)
                
                completion(sharingController)
            }
        }
    }
    
    public func itemTitle(for csc: UICloudSharingController) -> String? {
        return object.sharingTitle
    }
    
    public func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
        return object.sharingImage
    }
    
    public func itemType(for csc: UICloudSharingController) -> String? {
        return object.sharingType
    }
    
    public func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        if object.isOwnedByCurrentUser && object.shareRecordData == nil {
            object.setShareRecord(share: csc.share, in: persistentContainer)
        }
        
        didSaveShare?(csc.share!)
    }
    
    public func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        if object.isOwnedByCurrentUser {
            object.setShareRecord(share: nil, in: persistentContainer)
        }
        
        didStopSharing?()
    }
    
    public func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        didError?(error)
    }
    
}

#endif
