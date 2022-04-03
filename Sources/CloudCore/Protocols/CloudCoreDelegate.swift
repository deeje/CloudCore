//
//  CloudCoreDelegate.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 14/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation

/// Delegate for framework that can be used for proccesses tracking and error handling.
/// Maybe usefull to activate `UIApplication.networkActivityIndicatorVisible`.
/// All methods are optional.
public protocol CloudCoreDelegate: AnyObject {
	
	// MARK: Notifications
	
	/// Tells the delegate that fetching data from CloudKit is about to begin
	func willSyncFromCloud()
	
	/// Tells the delegate that data fetching from CloudKit and updating local objects processes are now completed
	func didSyncFromCloud()
	
	/// Tells the delegate that conversion operations (NSManagedObject to CKRecord) and data uploading to CloudKit is about to begin
	func willSyncToCloud()
	
	/// Tells the delegate that data has been uploaded to CloudKit
	func didSyncToCloud()
	
	// MARK: Error
	
	/// Tells the delegate that error has been occured, maybe called multiple times
	///
	/// - Parameters:
	///   - error: in most cases contains `CloudCoreError` or `CKError`
	///   - module: framework's module that throwed an error
	func error(error: Error, module: Module?)
	
}

public extension CloudCoreDelegate {
	
	func willSyncFromCloud() { }
	func didSyncFromCloud() { }
	func willSyncToCloud() { }
	func didSyncToCloud() { }
	func error(error: Error, module: Module?) { }
	
}
