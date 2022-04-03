//
//  RecordWithDatabase.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

class RecordWithDatabase {
	let record: CKRecord
	let database: CKDatabase
	
	init(_ record: CKRecord, _ database: CKDatabase) {
		self.record = record
		self.database = database
	}
}
