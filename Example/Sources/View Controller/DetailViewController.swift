//
//  DetailViewController.swift
//  CloudTest2
//
//  Created by Vasily Ulianov on 14.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import UIKit
import CoreData
import CloudCore

class DetailViewController: UITableViewController {

	var organizationID: NSManagedObjectID!
	let context = persistentContainer.viewContext
	
	private var tableDataSource: DetailTableDataSource!
	
    private var sharingController: CloudCoreSharingController!
    
	override func viewDidLoad() {
		super.viewDidLoad()
		
		let fetchRequest: NSFetchRequest<Employee> = Employee.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "organization == %@", organizationID)
		
		fetchRequest.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
		
		tableDataSource = DetailTableDataSource(fetchRequest: fetchRequest, context: context, sectionNameKeyPath: nil, delegate: self, tableView: tableView)
		tableView.dataSource = tableDataSource
		try! tableDataSource.performFetch()
        
        guard let organization = try? self.context.existingObject(with: self.organizationID) as? CloudCoreSharing else { return }
        
        var buttons: [UIBarButtonItem] = []
        if organization.isOwnedByCurrentUser {
            let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add(_:)))
            buttons.append(addButton)
            
            let renameButton = UIBarButtonItem(title: "Rename", style: .plain, target: self, action: #selector(rename(_:)))
            buttons.append(renameButton)
        }
        let shareButton = UIBarButtonItem(title: "Share", style: .plain, target: self, action: #selector((share(_:))))
        buttons.append(shareButton)
        
        navigationItem.setRightBarButtonItems(buttons, animated: false)
	}
    
	@objc private func add(_ sender: UIBarButtonItem) {
        persistentContainer.performBackgroundPushTask { (moc) in
            let employee = ModelFactory.insertEmployee(context: moc)
            let organization = try? moc.existingObject(with: self.organizationID) as? Organization
            employee.organization = organization
            
            try? moc.save()
        }
	}
	
	@objc private func rename(_ sender: UIBarButtonItem) {
        let newTitle = ModelFactory.newCompanyName()
        persistentContainer.performBackgroundPushTask { (moc) in
            let organization = try? moc.existingObject(with: self.organizationID) as? Organization
            organization?.name = newTitle
            
            try? moc.save()
        }
        self.title = newTitle
	}
    
    @objc private func share(_ sender: UIBarButtonItem) {
        iCloudAvailable { available in
            guard available else { return }
            
            guard let organization = try? self.context.existingObject(with: self.organizationID) as? CloudCoreSharing else { return }
            
            if self.sharingController == nil {
                self.sharingController = CloudCoreSharingController(persistentContainer: persistentContainer,
                                                                object: organization)
            }
            self.sharingController.configureSharingController(permissions: [.allowReadOnly, .allowPrivate, .allowPublic]) { csc in
                if let csc = csc {
                    csc.popoverPresentationController?.barButtonItem = sender
                    self.present(csc, animated:true, completion:nil)
                }
            }
        }
    }

}

extension DetailViewController: FRCTableViewDelegate {
	
	func frcTableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "Employee", for: indexPath) as! EmployeeTableViewCell
		let employee = tableDataSource.object(at: indexPath)
		
		cell.nameLabel.text = employee.name
		
		if let imageData = employee.photoData, let image = UIImage(data: imageData) {
			cell.photoImageView.image = image
		} else {
			cell.photoImageView.image = nil
		}
		
		var departmentText = employee.department ?? "No"
		departmentText += " department"
		cell.departmentLabel.text = departmentText
		
		var miniText = "Since "
		if let workingSince = employee.workingSince {
			miniText += DateFormatter.localizedString(from: workingSince, dateStyle: .medium, timeStyle: .none)
		} else {
			miniText += "unknown date"
		}
		
		cell.sinceLabel.text = miniText
		
		return cell
	}
	
}

extension DetailViewController {
    
    @available(iOS 11.0, *)
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteTitle = NSLocalizedString("Delete", comment: "Delete action")
        let deleteAction = UIContextualAction(style: .destructive, title: deleteTitle,
                                              handler: { [weak self] action, view, completionHandler in
                                                
                                                let anObject = self?.tableDataSource.object(at: indexPath)
                                                let objectID = anObject?.objectID
                                                
                                                persistentContainer.performBackgroundPushTask { (moc) in
                                                    if let objectToDelete = try? moc.existingObject(with: objectID!) {
                                                        moc.delete(objectToDelete)
                                                        try? moc.save()
                                                    }
                                                }
                                                
                                                completionHandler(true)
        })
        
        let configuration = UISwipeActionsConfiguration(actions: [deleteAction])
        return configuration
    }
    
}

fileprivate class DetailTableDataSource: FRCTableViewDataSource<Employee> {
    
}
