//
//  Person+CloudKit.swift
//  WTSDA
//
//  Created by deeje cooley on 12/28/18.
//  Copyright © 2018 deeje LLC.  All rights reserved.
//

import CoreData
import CloudKit
import UIKit
import CloudCore

extension Organization: CloudCoreSharing {
    
    public var sharingTitle: String? {
        return name
    }
    
    public var sharingType: String? {
        return "com.deeje.cloudcore.example.organization"
    }
    
    public var sharingImage: Data? {
        return nil
    }
    
    /*
    public var recordName: String? {
        return uuid
    }
    
    public var ownerName: String? {
        return ownerUUID
    }
    
    public var shareRecordData: Data? {
        get {
            return shareData
        }
        set {
            shareData = newValue
        }
    }
    */

}
