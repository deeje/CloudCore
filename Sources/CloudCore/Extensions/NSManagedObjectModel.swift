//
//  NSManagedObjectModel.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 12/12/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData

extension NSManagedObjectModel {
	
	var cloudCoreEnabledEntities: [NSEntityDescription] {
		var cloudCoreEntities = [NSEntityDescription]()
		
		for entity in self.entities {
			if entity.serviceAttributeNames != nil {
				cloudCoreEntities.append(entity)
			}
		}
		
		return cloudCoreEntities
	}
	
}
