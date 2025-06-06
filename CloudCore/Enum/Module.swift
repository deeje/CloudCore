//
//  Module.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 14/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation

/// Enumeration with module name that issued an error in `CloudCoreErrorDelegate`
public enum Module {
	
	case pushToCloud
	
	case pullFromCloud
    
    case cacheToCloud
    
    case cacheFromCloud
	
}
