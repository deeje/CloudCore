//
//  CloudCore.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 06.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

/**
	Main framework class, in most cases you will use only methods from this class, all methods and properties are `static`.

	## Save to cloud
	On application inialization call `CloudCore.enable(persistentContainer:)` method, so framework will automatically monitor changes at Core Data and upload it to iCloud.

	### Example
	```swift
	func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
		// Register for push notifications about changes
		application.registerForRemoteNotifications()

		// Enable CloudCore syncing
		CloudCore.delegate = someDelegate // it is recommended to set delegate to track errors
		CloudCore.enable(persistentContainer: persistentContainer)

		return true
	}
	```

	## Fetch from cloud
	When CloudKit data is changed **push notification** is posted to an application. You need to handle it and fetch changed data from CloudKit with `CloudCore.pull(using:to:error:completion:)` method.

	### Example
	```swift
	func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
		// Check if it CloudKit's and CloudCore notification
		if CloudCore.isCloudCoreNotification(withUserInfo: userInfo) {
			// Fetch changed data from iCloud
			CloudCore.pull(using: userInfo, to: persistentContainer, error: nil, completion: { (fetchResult) in
				completionHandler(fetchResult.uiBackgroundFetchResult)
			})
		}
	}
	```

	You can also check for updated data at CloudKit **manually** (e.g. push notifications are not working). Use for that `CloudCore.pull(to:error:completion:)`
*/
open class CloudCore {
	
	// MARK: - Properties
	
    private(set) static var processContext: NSManagedObjectContext!
    
	private(set) static var coreDataObserver: CoreDataObserver?
    private(set) static var cacheManager: CloudCoreCacheManager?
    public static var isOnline: Bool {
        get {
            return coreDataObserver?.isOnline ?? false
        }
        set {
            coreDataObserver?.isOnline = newValue
        }
    }
    
	/// CloudCore configuration, it's recommended to set up before calling any of CloudCore methods. You can read more at `CloudCoreConfig` struct description
	public static var config = CloudCoreConfig()
	
	/// `Tokens` object, read more at class description. By default variable is loaded from User Defaults.
	public static var tokens = Tokens.loadFromUserDefaults()
	
	/// Error and sync actions are reported to that delegate
	public static weak var delegate: CloudCoreDelegate? {
		didSet {
			coreDataObserver?.delegate = delegate
		}
	}
	
	public typealias NotificationUserInfo = [AnyHashable : Any]
	
    public static var userRecordID: CKRecord.ID? = nil
    
    static private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
	
        // if CloudKit says to retry later…
    private static var pauseTimer: Timer?
    static var pauseUntil: Date? {
        didSet {
            DispatchQueue.main.async {
                CloudCore.pauseTimer?.invalidate()
                if let fireDate = CloudCore.pauseUntil {
                    let interval = fireDate.timeIntervalSinceNow
                    print("pausing for \(interval) seconds")
                    CloudCore.pauseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { timer in
                        CloudCore.pauseUntil = nil
                        
                        CloudCore.coreDataObserver?.processPersistentHistory()
                        CloudCore.cacheManager?.restartOperations()
                    }
                }
            }
        }
    }
    
	// MARK: - Methods
	
	/// Enable CloudKit and Core Data synchronization
	///
	/// - Parameters:
	///   - container: `NSPersistentContainer` that will be used to save data
	public static func enable(persistentContainer: NSPersistentContainer) {
            // share a MOC between CoreDataObserver and CacheManager
        let processContext = persistentContainer.newBackgroundContext()
        processContext.name = "CloudCoreProcess"
        processContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        processContext.automaticallyMergesChangesFromParent = true
        self.processContext = processContext
        
		// Listen for local changes
		let observer = CoreDataObserver(persistentContainer: persistentContainer, processContext: processContext)
		observer.delegate = self.delegate
		observer.start()
		self.coreDataObserver = observer
		
        self.cacheManager = CloudCoreCacheManager(persistentContainer: persistentContainer, processContext: processContext)
        
		// Subscribe (subscription may be outdated/removed)
		let subscribeOperation = SubscribeOperation()
		subscribeOperation.errorBlock = {
            handle(subscriptionError: $0, container: persistentContainer)
        }
		
		// Fetch updated data (e.g. push notifications weren't received)
        let pullOperation = PullChangesOperation(persistentContainer: persistentContainer)
		pullOperation.errorBlock = {
			self.delegate?.error(error: $0, module: .some(.pullFromCloud))
		}
        
        queue.addOperation(subscribeOperation)
        queue.addOperation(pullOperation)
        
        config.container.fetchUserRecordID { recordID, error in
            if error == nil {
                self.userRecordID = recordID
            }
        }
	}
	
	/// Disables synchronization (push notifications won't be sent also)
	public static func disable() {
		queue.cancelAllOperations()

		coreDataObserver?.stop()
		coreDataObserver = nil
		
		// FIXME: unsubscribe
	}
	
    /// return the user's record name
    public static func userRecordName() -> String? {
        return userRecordID?.recordName
    }
    
	// MARK: Fetchers
	
	/** Fetch changes from one CloudKit database and save it to CoreData from `didReceiveRemoteNotification` method.

	Don't forget to check notification's UserInfo by calling `isCloudCoreNotification(withUserInfo:)`. If incorrect user info is provided `PullResult.noData` will be returned at completion block.

	- Parameters:
		- userInfo: notification's user info, CloudKit database will be extraced from that notification
		- container: `NSPersistentContainer` that will be used to save fetched data
		- error: block will be called every time when error occurs during process
		- completion: `PullResult` enumeration with results of operation
	*/
	public static func pull(using userInfo: NotificationUserInfo, to container: NSPersistentContainer, error: ErrorBlock?, completion: @escaping (_ fetchResult: PullResult) -> Void) {
		guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo), let cloudDatabase = self.database(for: notification) else {
			completion(.noData)
			return
		}
        
        var hadError = false
        let pullChangesOp = PullChangesOperation(from: [cloudDatabase], persistentContainer: container)
        pullChangesOp.errorBlock = {
            hadError = true
            error?($0)
        }
        pullChangesOp.completionBlock = {
            completion(hadError ? PullResult.failed : PullResult.newData)
        }
        
        queue.addOperation(pullChangesOp)
	}

	/** Fetch changes from all CloudKit databases and save it to Core Data

	- Parameters:
		- container: `NSPersistentContainer` that will be used to save fetched data
		- error: block will be called every time when error occurs during process
		- completion: `PullResult` enumeration with results of operation
	*/
	public static func pull(to container: NSPersistentContainer, error: ErrorBlock?, completion: ((_ fetchResult: PullResult) -> Void)?) {
        var hadError = false
        let operation = PullChangesOperation(persistentContainer: container)
		operation.errorBlock = {
            hadError = true
            error?($0)
        }
		operation.completionBlock = {
            completion?(hadError ? PullResult.failed : PullResult.newData)
        }
        
		queue.addOperation(operation)
	}
	
    /** Fetch one full record from all CloudKit databases and save it to Core Data

    - Parameters:
        - recordID: `CKRecord.ID` identifies the record to retrieve
        - database: `CKDatabase` identifies which database from the container to use
        - container: `NSPersistentContainer` that will be used to save fetched data
        - error: block will be called every time when error occurs during process
        - completion: `PullResult` enumeration with results of operation
    */
    public static func pull(rootRecordID: CKRecord.ID,
                            database: CKDatabase = config.container.sharedCloudDatabase,
                            container: NSPersistentContainer,
                            error: ErrorBlock?,
                            completion: (() -> Void)?) {
        let operation = PullRecordOperation(rootRecordID: rootRecordID,
                                            database: database,
                                            persistentContainer: container)
        operation.errorBlock = error
        operation.completionBlock = completion
        
        queue.addOperation(operation)
    }
    
	/** Check if notification is CloudKit notification containing CloudCore data

	 - Parameter userInfo: userInfo of notification
	 - Returns: `true` if notification contains CloudCore data
	*/
	public static func isCloudCoreNotification(withUserInfo userInfo: NotificationUserInfo) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        
		return (database(for: notification) != nil)
	}
	
	static func database(for notification: CKNotification) -> CKDatabase? {
		guard let id = notification.subscriptionID else { return nil }
		
		switch id {
		case config.subscriptionIDForPrivateDB: return config.container.privateCloudDatabase
		case config.subscriptionIDForSharedDB: return config.container.sharedCloudDatabase
		case _ where id.hasPrefix(config.publicSubscriptionIDPrefix): return config.container.publicCloudDatabase
		default: return nil
		}
	}

	static private func handle(subscriptionError: Error, container: NSPersistentContainer) {
		guard let cloudError = subscriptionError as? CKError,
              let partialErrorValues = cloudError.partialErrorsByItemID?.values else {
			delegate?.error(error: subscriptionError, module: nil)
			return
		}
		
		// Try to find "Zone Not Found" in partial errors
		for subError in partialErrorValues {
			guard let subError = subError as? CKError else { continue }
			
            switch subError.code {
            case .userDeletedZone:      // 2025-01 this doesn't appear to ever happen here :-(
                self.queue.cancelAllOperations()
                let setupOperation = SetupOperation(container: container, uploadAllData: true)
                self.queue.addOperation(setupOperation)
                
            case .zoneNotFound:
                // Zone wasn't found, we need to create it
                self.queue.cancelAllOperations()
                
                let setupOperation = SetupOperation(container: container, uploadAllData: true)  // arg, why is this a question?!
                
                // for completeness, pull again
                let pullOperation = PullChangesOperation(persistentContainer: container)
                pullOperation.errorBlock = {
                    self.delegate?.error(error: $0, module: .some(.pullFromCloud))
                }
                
                self.queue.addOperation(setupOperation)
                self.queue.addOperation(pullOperation)
            default:
                print("Unknown CK sub error: \(subError)")
                break
            }
		}
		
		delegate?.error(error: subscriptionError, module: nil)
	}
    
    static public func perform(completion: ((CKContainer) -> Void)) {
        let container = config.container
        
        if #available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *) {
            let ckConfig = CKOperation.Configuration()
//            ckConfig.container = container
            ckConfig.qualityOfService = .userInitiated
            ckConfig.allowsCellularAccess = true
            container.configuredWith(configuration: ckConfig, group: nil) { configuredContainer in
                completion(configuredContainer)
            }
        } else {
            completion(container)
        }
    }
    
    static public func iCloudAvailable(completion: @escaping ((Bool) -> Void)) {
        CloudCore.config.container.accountStatus { accountStatus, error in
            DispatchQueue.main.async {
                switch accountStatus {
                case .available:
                    completion(true)
                
                case .couldNotDetermine, .restricted, .noAccount, .temporarilyUnavailable:
                    completion(false)
                @unknown default:
                    completion(false)
                }
            }
        }
    }

    
}
