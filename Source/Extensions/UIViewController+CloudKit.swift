//
//  UIViewController+CloudKit.swift
//  CloudCore
//
//  Created by deeje cooley on 12/5/20.
//

#if os(iOS)

import UIKit
import CloudKit

extension UIViewController {
    
    public func iCloudAvailable(withPrompt: Bool = true, completion: @escaping ((Bool) -> Void)) {
        CloudCore.config.container.accountStatus { accountStatus, error in
            DispatchQueue.main.async {
                var available = false
                
                var title: String?
                var message: String?
                
                switch accountStatus {
                case .noAccount:
                    title = "Sign in to iCloud and\nenable iCloud Drive"
                    message = "Go to Settings and sign into your iPhone. Under iCloud, enable iCloud Drive."
                    
                case .available:
                    available = true
                    
                case .couldNotDetermine:
                    title = "iCloud Unavailable"
                    message = "Could not determine the status of your iCloud account"
                    
                case .restricted:
                    title = "iCloud Restricted"
                    message = "You'll need permissions changed on your iCloud account"
                    
                @unknown default:
                    break
                }
                
                if withPrompt, let title = title, let message = message {
                    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in }))
                    self.present(alert, animated: true) {
                        completion(available)
                    }
                } else {
                    completion(available)
                }
            }
        }
    }
    
}

#endif
