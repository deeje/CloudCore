//
//  RecordIDWithDatabase.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

class RecordIDWithDatabase {
    let recordID: CKRecord.ID
	let database: CKDatabase
	
    init(_ recordID: CKRecord.ID, _ database: CKDatabase) {
		self.recordID = recordID
		self.database = database
	}
}
