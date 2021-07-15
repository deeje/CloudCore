# CloudCore

![Platform](https://img.shields.io/cocoapods/p/CloudCore.svg?style=flat)
![Status](https://img.shields.io/badge/status-beta-orange.svg)
![Swift](https://img.shields.io/badge/swift-5.0-orange.svg)

**CloudCore** is a framework that manages syncing between iCloud (CloudKit) and Core Data written on native Swift.

#### Features
* Leveraging **NSPersistentHistory**, local changes are pushed to CloudKit when online
* Pull manually or on CloudKit **remote notifications**.
* **Differential sync**, only changed object and values are uploaded and downloaded.
* Core Data relationships are preserved
* **private database** and **shared database** push and pull is supported.
* **public database** push is supported
* Parent-Child relationships can be defined for CloudKit Sharing
* Respects Core Data options (cascade deletions, external storage).
* Knows and manages CloudKit errors like `userDeletedZone`, `zoneNotFound`, `changeTokenExpired`, `isMore`.
* Available on iOS, iPadOS, and watchOS (tvOS hasn't been tested)
* Sharing can be extended to your NSManagedObject classes, and native SharingUI is implemented

#### CloudCore vs iOS 13?

At WWDC 2019, Apple announced support for NSPersistentCloudKitContainer in iOS 13, which provides native support for Core Data <-> CloudKit synchronization.  Here are some initial thoughts on the differences between these two approaches.

###### NSPersistentCloudKitContainer
* Simple to enable
* Private or(?) Public Database only, no Sharing
* Synchronizes All Records
* No CloudKit Metadata (e.g. recordName, systemFields, owner)
* Record-level Synchronization (entire objects are pushed)
* Offline Synchronization is opaque, but doesn't appear to require NSPersistentHistoryTracking
* All Core Data names are preceeded with "CD_" in CloudKit
* Core Data Relationships are mapped thru CDMR records in CloudKit
* Uses a specific custom zone in the Private Database

###### CloudCore
* Support requires specific configuration in the Core Data Model
* Support for Private, Shared, and Public databases
* Selective Synchronization (e.g. can delete local objects without deleting remote records)
* Explicit CloudKit Metadata
* Field-level Synchronization (only changed attributes are pushed)
* Offline Synchronziation via NSPersistentHistoryTracking
* Core Data names are mapped exactly in CloudKit
* Core Data Relationships are mapped to CloudKit CKReferences

During their WWDC presentation, Apple very clearly stated that NSPersistentCloudKitContainer is a foundation for future support of more advanced features #YMMV

## How it works?
CloudCore is built using a "black box" architecture, so it works invisibly for your application.  You just need to add several lines to your `AppDelegate` to enable it, as well as identify various aspects of your Core Data Model schema. Synchronization and error resolving is managed automatically.

1. CloudCore stores *change tokens* from CloudKit, so only changed data is downloaded.
2. When CloudCore is enabled (`CloudCore.enable`) it pulls changed data from CloudKit and subscribes to CloudKit push notifications about new changes.
3. When `CloudCore.pull` is called manually or by push notification, CloudCore pulls and saves changed data to Core Data.
4. When data is written to your persistent container (parent context is saved) CloudCore finds locally changed data and pushes to CloudKit.
5. By leveraging NSPersistentHistory, changes can be queued when offline and pushed when online.

## Installation

### CocoaPods
**CloudCore** is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'CloudCore'
```

## How to help?
Current version of framework hasn't been deeply tested and may contain errors. If you can test framework, I will be very glad. If you found an error, please post [an issue](https://github.com/deeje/CloudCore/issues).

## Quick start
1. Enable CloudKit capability for you application:

![CloudKit capability](https://cloud.githubusercontent.com/assets/5610904/25092841/28305bc0-2398-11e7-9fbf-f94c619c264f.png)

2. For each entity type you want to sync, add this key: value pair to the UserInfo record of the entity:
* `CloudCoreScopes`: `private`

3. Also add 4 attributes to each entity:
  * `privateRecordData` attribute with `Binary` type
  * `publicRecordData` attribute with `Binary` type
  * `recordName` attribute with `String` type
  * `ownerName` attribute with `String` type

4. And enable 'Preserve After Deletion' for the following attributes
  * `privateRecordData` 
  * `publicRecordData`

5. Make changes in your **AppDelegate.swift** file:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
  // Register for push notifications about changes
  application.registerForRemoteNotifications()

  // Enable CloudCore syncing
  CloudCore.enable(persistentContainer: persistentContainer)

  return true
}

// Notification from CloudKit about changes in remote database
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

6. If you want to enable offline support, **enable NSPersistentHistoryTracking** when you initialize your Core Data stack

```swift
lazy var persistentContainer: NSPersistentContainer = {
  let container = NSPersistentContainer(name: "YourApp")

  let storeDescription = container.persistentStoreDescriptions.first
  storeDescription?.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)

  container.loadPersistentStores { storeDescription, error in
    if let error = error as NSError? {
      // Replace this implementation with code to handle the error appropriately.                
    }
  }
  return container
}()
```

7. To identify changes from your app that should be pushed, **save** from a background ManagedObjectContext named `CloudCorePushContext`, or use the convenience function performBackgroundPushTask

```swift
persistentContainer.performBackgroundPushTask { moc in
  // make changes to objects, properties, and relationships you want pushed via CloudCore
  try? context.save()
}
```

8. Make first run of your application in a development environment, fill an example data in Core Data and wait until sync completes. CloudKit will create needed schemas automatically.

## Service attributes
CloudCore stores CloudKit information inside your managed objects, so you need to add attributes to your Core Data model for that. If required attributes are not found in an entity, that entity won't be synced.

Required attributes for each synced entity:
1. *Private Record Data* attribute with `Binary` type
2. *Public Record Data* attribute with `Binary` type
3. *Record Name* attribute with `String` type
4. *Owner Name* attribute with `String` type

You may specify attributes' names in one of two 2 ways (you may combine that ways in different entities).

### Default names
The most simple way is to name attributes with default names because you don't need to map them in UserInfo.

### Mapping via UserInfo
You can map your own attributes to the required service attributes.  For each attribute you want to map, add an item to the attribute's UserInfo, using the key `CloudCoreType` and following values:
* *Private Record Data* value is `privateRecordData`.
* *Public Record Data* value is `publicRecordData`.
* *Record Name* value is `recordName`.
* *Owner Name* value is `ownerName`.

![Model editor User Info](https://cloud.githubusercontent.com/assets/5610904/24004400/52e0ff94-0a77-11e7-9dd9-e1e24a86add5.png)

When your *entities have relationships*, CloudCore will look for the following key:value pair in the UserInfo of your entities:

`CloudCoreParent`: name of the to-one relationship property in your entity

### 💡 Tips
* I recommend to set the *Record Name* attribute as `Indexed`, to speed up updates in big databases.
* *Record Data* attributes are used to store archived version of `CKRecord` with system fields only (like timestamps, tokens), so don't worry about size, no real data will be stored here.

## CloudKit Sharing
CloudCore now has built-in support for CloudKit Sharing.  There are several additional steps you must take to enable it in your application.

1. Add the CKSharingSupported key, with value true, to your info.plist

2. Implement the appropriate delegate(… userDidAcceptCloudKitShare), something like…

```swift
func windowScene(_ windowScene: UIWindowScene, 
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
```

OR

```swift
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
```

Note that when a user accepts a share, the app does not receive a remote notification of changes from iCloud, and so it must specifically pull the shared record in.

3. Use a CloudCoreSharingController to configure a UICloudSharingController for presentation

4. When a user wants to delete an object, your app must distinguish between the owner and a sharer, and either delete the object or the share.

## Example application
You can find example application at [Example](/Example/) directory, which has been updated to demonstrate sharing.

**How to run it:**
1. Set Bundle Identifier.
2. Check that embedded binaries has a correct path (you can remove and add again CloudCore.framework).
3. If you're using simulator, login at iCloud on it.

**How to use it:**
* **+** button adds new object to local storage (that will be automatically synced to Cloud)
* **Share* button presents the CloudKit Sharing UI
* **refresh** button calls `pull` to fetch data from Cloud. That is only useful for simulators because Simulator unable to receive push notifications
* Use [CloudKit dashboard](https://icloud.developer.apple.com/dashboard/) to make changes and see it at application, and make change in application and see ones in dashboard. Don't forget to refresh dashboard's page because it doesn't update data on-the-fly.

## Tests
CloudKit objects can't be mocked up, that's why there are 2 different types of tests:

* `Tests/Unit` here I placed tests that can be performed without CloudKit connection. That tests are executed when you submit a Pull Request.
* `Tests/CloudKit` here located "manual" tests, they are most important tests that can be run only in configured environment because they work with CloudKit and your Apple ID.

  Nothing will be wrong with your account, tests use only private `CKDatabase` for application.

  **Please run these tests before opening pull requests.**

To run them you need to:

  1. Change `TestableApp` bundle id.
  2. Run in simulator or real device `TestableApp` target.
  3. Configure iCloud on that device: Settings.app → iCloud → Login.
  4. Run `CloudKitTests`, they are attached to `TestableApp`, so CloudKit connection will work.

## Roadmap

- [ ] Add methods to clear local cache and remote database
- [ ] Add error resolving for `limitExceeded` error (split saves by relationships).

## Authors

deeje cooley, [deeje.com](http://www.deeje.com/)
- added NSPersistentHistory and CloudKit Sharing Support

Vasily Ulianov, [va...@me.com](http://www.google.com/recaptcha/mailhide/d?k=01eFEpy-HM-qd0Vf6QGABTjw==&c=JrKKY2bjm0Bp58w7zTvPiQ==)
Open for hire / relocation.
- implemented version 1 and 2, with dynamic mapping between CoreData and CloudKit

Oleg Müller
- added full support for CoreData relationships
