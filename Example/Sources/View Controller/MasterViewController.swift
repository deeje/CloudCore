//
//  MasterViewController.swift
//  CloudTest2
//
//  Created by Vasily Ulianov on 14.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import UIKit
import CoreData
import CloudCore

class MasterViewController: UITableViewController {

	private var tableDataSource: MasterTableViewDataSource!
	
	var mockAddNewOrganization: Organization?
	let context = persistentContainer.viewContext
	
	// MARK: - UIViewController methods

	override func viewDidLoad() {
		super.viewDidLoad()
		        
		let fetchRequest: NSFetchRequest<Organization> = Organization.fetchRequest()
		fetchRequest.sortDescriptors = [NSSortDescriptor(key: "sort", ascending: true)]
		tableDataSource = MasterTableViewDataSource(fetchRequest: fetchRequest, context: context, sectionNameKeyPath: nil, delegate: self, tableView: tableView)
		tableView.dataSource = tableDataSource
		try! tableDataSource.performFetch()
		
		self.clearsSelectionOnViewWillAppear = true
	}
    
	@IBAction func addButtonClicked(_ sender: UIBarButtonItem) {
        persistentContainer.performBackgroundPushTask { (moc) in
            ModelFactory.insertOrganizationWithEmployees(context: moc)
            try! moc.save()
        }
	}
	
	@IBAction func refreshValueChanged(_ sender: UIRefreshControl) {
		CloudCore.pull(to: persistentContainer, error: { (error) in
			print("⚠️ FetchAndSave error: \(error)")
			DispatchQueue.main.async {
				sender.endRefreshing()
			}
		}) {
			DispatchQueue.main.async {
				sender.endRefreshing()
			}
		}
	}
	
	// MARK: - Segues

	override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
		if let cell = sender as? UITableViewCell, let indexPath = tableView.indexPath(for: cell), let detailVC = segue.destination as? DetailViewController {
			let organization = tableDataSource.object(at: indexPath)
			detailVC.organizationID = organization.objectID
			detailVC.title = organization.name
		}
	}

	override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
		return .delete
	}
	
}

extension MasterViewController: FRCTableViewDelegate {
	
	func frcTableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "RightDetail", for: indexPath)
		let organization = tableDataSource.object(at: indexPath)
		
		cell.textLabel?.text = organization.name
		
		let employeesCount = organization.employees?.count ?? 0
		cell.detailTextLabel?.text = String(employeesCount) + " employees"
		
		return cell
	}
	
}

extension MasterViewController {

    @available(iOS 11.0, *)
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        var actions: [UIContextualAction] = []
        
        let anObject = tableDataSource.object(at: indexPath) as Organization
        if anObject.isOwnedByCurrentUser {
            let deleteTitle = NSLocalizedString("Delete", comment: "Delete action")
            let deleteAction = UIContextualAction(style: .destructive, title: deleteTitle) { [weak self] action, view, completionHandler in
                self?.confirmDelete(objectID: anObject.objectID, completion: completionHandler)
            }
            actions.append(deleteAction)
        } else {
            let RemoveTitle = NSLocalizedString("Remove", comment: "Remove action")
            let removeAction = UIContextualAction(style: .destructive, title: RemoveTitle) { [weak self] action, view, completionHandler in
                self?.confirmRemove(objectID: anObject.objectID, completion: completionHandler)
            }
            actions.append(removeAction)
        }
        
        let configuration = UISwipeActionsConfiguration(actions: actions)
        return configuration
    }
    
    func confirmDelete(objectID: NSManagedObjectID, completion: @escaping ((Bool) -> Void) ) {
        let alert = UIAlertController(title: "Are you sure you want to delete?", message: "This will permanently delete this object from all devices", preferredStyle: .alert)
        let confirm = UIAlertAction(title: "Delete", style: .destructive) { _ in
            persistentContainer.performBackgroundPushTask { moc in
                if let personEntity = try? moc.existingObject(with: objectID) {
                    moc.delete(personEntity)
                    try? moc.save()
                }
                completion(true)
            }
        }
        alert.addAction(confirm)
        let cancel = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        }
        alert.addAction(cancel)
        self.present(alert, animated: true)
    }
    
    func confirmRemove(objectID: NSManagedObjectID, completion: @escaping ((Bool) -> Void) ) {
        let alert = UIAlertController(title: "Are you sure you want to remove?", message: "This will permanently remove this object from all your devices", preferredStyle: .alert)
        let confirm = UIAlertAction(title: "Remove", style: .destructive) { _ in
            guard let object = (try? self.context.existingObject(with: objectID)) as? Organization else { return }
            
            object.stopSharing(in: persistentContainer) { didStop in
                if didStop {
                    persistentContainer.performBackgroundTask { moc in
                        if let deleteObject = try? moc.existingObject(with: objectID) {
                            moc.delete(deleteObject)
                            try? moc.save()
                        }
                        completion(true)
                    }
                } else {
                    completion(false)
                }
            }
        }
        alert.addAction(confirm)
        let cancel = UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        }
        alert.addAction(cancel)
        self.present(alert, animated: true)
    }

}

fileprivate class MasterTableViewDataSource: FRCTableViewDataSource<Organization> {
		
}

