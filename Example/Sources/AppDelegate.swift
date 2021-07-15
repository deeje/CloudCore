//
//  AppDelegate.swift
//  CloudTest2
//
//  Created by Vasily Ulianov on 14.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import UIKit
import CoreData
import CloudCore
import Connectivity

let persistentContainer = (UIApplication.shared.delegate as! AppDelegate).persistentContainer

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UISplitViewControllerDelegate {
	
	let delegateHandler = CloudCoreDelegateHandler()
    
    var connectivity: Connectivity?
    
	func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
		// Register for push notifications about changes
		application.registerForRemoteNotifications()
		
		// Enable uploading changed local data to CoreData
		CloudCore.delegate = delegateHandler
		CloudCore.enable(persistentContainer: persistentContainer)
		
        let connectivityChanged: (Connectivity) -> Void = { connectivity in
            let online : [ConnectivityStatus] = [.connected, .connectedViaCellular, .connectedViaWiFi]
            CloudCore.isOnline = online.contains(connectivity.status)
        }
        
        connectivity = Connectivity(shouldUseHTTPS: false)
        connectivity?.whenConnected = connectivityChanged
        connectivity?.whenDisconnected = connectivityChanged
        connectivity?.startNotifier()
        
		return true
	}
	    
	// Notification from CloudKit about changes in remote database
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		// Check if it CloudKit's and CloudCore notification
		if CloudCore.isCloudCoreNotification(withUserInfo: userInfo) {
			// Fetch changed data from iCloud
			CloudCore.pull(using: userInfo, to: persistentContainer, error: {
				print("fetchAndSave from didReceiveRemoteNotification error: \($0)")
			}, completion: { (fetchResult) in
				completionHandler(fetchResult.uiBackgroundFetchResult)
			})
		}
	}
    
    // User accepted a sharing link, pull the complete record
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        let acceptShareOperation = CKAcceptSharesOperation(shareMetadatas: [cloudKitShareMetadata])
        acceptShareOperation.qualityOfService = .userInteractive
        acceptShareOperation.perShareCompletionBlock = { meta, share, error in
            CloudCore.pull(rootRecordID: meta.rootRecordID, container: self.persistentContainer, error: nil) { }
        }
        acceptShareOperation.acceptSharesCompletionBlock = { error in
            // N/A
        }
        CKContainer(identifier: cloudKitShareMetadata.containerIdentifier).add(acceptShareOperation)
    }
    
	// MARK: - Default Apple initialization, you can skip that
	
	var window: UIWindow?

	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
		return true
	}
	
	// MARK: Core Data stack

	lazy var persistentContainer: NSPersistentContainer = {
	    /*
	     The persistent container for the application. This implementation
	     creates and returns a container, having loaded the store for the
	     application to it. This property is optional since there are legitimate
	     error conditions that could cause the creation of the store to fail.
	    */
	    let container = NSPersistentContainer(name: "Model")
        
        if #available(iOS 11.0, *) {
            let storeDescription = container.persistentStoreDescriptions.first
            storeDescription?.setOption(true as NSNumber, forKey:NSPersistentHistoryTrackingKey)
        }
        
	    container.loadPersistentStores(completionHandler: { (storeDescription, error) in
	        if let error = error as NSError? {
	            // Replace this implementation with code to handle the error appropriately.
	            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
	             
	            /*
	             Typical reasons for an error here include:
	             * The parent directory does not exist, cannot be created, or disallows writing.
	             * The persistent store is not accessible, due to permissions or data protection when the device is locked.
	             * The device is out of space.
	             * The store could not be migrated to the current model version.
	             Check the error message to determine what the actual problem was.
	             */
	            fatalError("Unresolved error \(error), \(error.userInfo)")
	        }
	    })
		container.viewContext.automaticallyMergesChangesFromParent = true
                
	    return container
	}()

	// MARK: Core Data Saving support

	func saveContext () {
	    let context = persistentContainer.viewContext
	    if context.hasChanges {
	        do {
	            try context.save()
	        } catch {
	            // Replace this implementation with code to handle the error appropriately.
	            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
	            let nserror = error as NSError
	            fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
	        }
	    }
	}

}

