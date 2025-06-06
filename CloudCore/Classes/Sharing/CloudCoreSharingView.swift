//
//  CloudCoreSharingView.swift
//  CloudCore
//
//  Created by deeje cooley on 6/27/23.
//

#if os(iOS)

import SwiftUI
import CoreData
import CloudKit

public struct CloudCoreSharingView: UIViewControllerRepresentable {

    private let persistentContainer: NSPersistentContainer
    private let object: CloudCoreSharing
    private let share: CKShare
    private let permissions: UICloudSharingController.PermissionOptions
    
    public init(persistentContainer: NSPersistentContainer, object: CloudCoreSharing, share: CKShare, permissions: UICloudSharingController.PermissionOptions) {
        self.persistentContainer = persistentContainer
        self.object = object
        self.share = share
        self.permissions = permissions
    }
    
    public func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}
    
    public func makeUIViewController(context: Context) -> some UIViewController {
        let sharingController = context.coordinator.createSharingController(share: share, permissions: permissions, container: CloudCore.config.container)
        sharingController.modalPresentationStyle = .formSheet
        
        return sharingController
    }
    
    public func makeCoordinator() -> CloudCoreSharingController {
        CloudCoreSharingController(persistentContainer: persistentContainer, object: object)
    }
    
}

#endif
