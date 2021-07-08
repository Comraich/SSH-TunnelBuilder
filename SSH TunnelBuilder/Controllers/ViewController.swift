//
//  ViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Cocoa
import AppKit
import CloudKit
import Foundation

class ViewController: NSViewController {
    
    // MARK: Global variables
    @IBOutlet var tableView: NSTableView!
    @IBOutlet weak var connectionComboBox: NSComboBox!
    var viewModel = ViewModel()
    var activeConnections = Dictionary<Int, TableViewConnectionRecords>()
    let privateDB = CKContainer.default().privateCloudDatabase
    
    // MARK: Application View Setup
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        // Set View delegate and data source
        tableView.delegate = self
        tableView.dataSource = self
        
        connectionComboBox.usesDataSource = true
        connectionComboBox.dataSource = self
    
    }
    
    override func viewWillAppear() {
        
        super.viewWillAppear()
        checkIcloudAccountStatus()
        loadIcloudData()
        tableView.reloadData()
        connectionComboBox.reloadData()
        
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        // Make the main window non-resizable
        self.view.window?.styleMask.remove(NSWindow.StyleMask.resizable)
        self.view.window?.title = "SSH TunnelBuilder"
        
    }

    @objc func loadIcloudData() {
        
        if (self.connectionComboBox.indexOfSelectedItem != -1) {
            
            self.connectionComboBox.deselectItem(at: self.connectionComboBox.indexOfSelectedItem)
            
        }
        
        self.connectionComboBox.stringValue = ""
        
        
        viewModel.refresh { error in
            if let error = error {
                
                Utilities.ShowAlertBox( alertStyle: NSAlert.Style.critical,
                                        message: error.localizedDescription )
                return
                
            } else {
                
                self.setupMenus()
                
                if self.numberOfItems(in: self.connectionComboBox) == 0 {
                    
                    Utilities.ShowAlertBox( alertStyle: NSAlert.Style.informational,
                                            message: "You do not have any connections defined. Go to File -> Create new connection or File -> Import connections to get started." )
                    
                }
                
            }
        }
        
        DispatchQueue.main.async {
            
            self.tableView.reloadData()
            
        }
    }
    
    override var representedObject: Any? {
        didSet {
            
            tableView.reloadData()
            connectionComboBox.reloadData()
            
        }
    }

    func checkIcloudAccountStatus() {
        
        CKContainer.default().accountStatus { accountStatus, error in
            if accountStatus == .noAccount {
                
                Utilities.ShowAlertBox( alertStyle: NSAlert.Style.critical,
                                        message: "This app uses iCloud to store your connection settings. Please sign in to iCloud in System Preferences.")
                return
                
            }
        }
    }
    
    // MARK: Setup Application menu
    func createMenuItems(_ selector: Selector) -> [NSMenuItem] {
        
        var menuItems = [NSMenuItem]()
        
        for connection in viewModel.connections {
            
            let newItem: NSMenuItem = NSMenuItem(title: connection.connectionName, action: selector, keyEquivalent: "")
            newItem.identifier = NSUserInterfaceItemIdentifier(rawValue: String(connection.connectionId))
            menuItems.append(newItem)
            
        }
        
        return menuItems
        
    }
    
    func setupMenus() {
        
        guard let mainMenu = (NSApp.delegate as? AppDelegate)?.fileMenu else { return }
        guard let editMenuItem = mainMenu.item(withTitle: "Edit Connection") else { return }
        guard let deleteMenuItem = mainMenu.item(withTitle: "Delete Connection") else { return }
        
        editMenuItem.submenu?.removeAllItems()
        deleteMenuItem.submenu?.removeAllItems()
        
        let editConnectionMenuItems = createMenuItems(#selector(presentEditConnectionSheet))
        editConnectionMenuItems.forEach { editMenuItem.submenu?.addItem($0) }
        
        let deleteConnectionMenuItems = createMenuItems(#selector(deleteConnection))
        deleteConnectionMenuItems.forEach { deleteMenuItem.submenu?.addItem($0) }
        
    }

    // MARK: Create / Edit / Delete Connection definitions
    @objc func presentNewConnectionSheet(_ sender: NSMenuItem) {
        
        let storyboard = NSStoryboard(name: "Connection", bundle: nil)
        let connectionViewController = storyboard.instantiateController(withIdentifier: "ConnectionPromptId")
        presentAsSheet(connectionViewController as! ConnectionViewController)
        
    }
    
    @objc func presentEditConnectionSheet(_ sender: NSMenuItem) {
        
        let connectionId = Int(sender.identifier!.rawValue)
        let storyboard = NSStoryboard(name: "Connection", bundle: nil)
        let connectionViewController = storyboard.instantiateController(withIdentifier: "ConnectionPromptId") as! ConnectionViewController
        let connection = viewModel.getConnection(connectionId: connectionId!)
        connectionViewController.setConnection(connection: connection)
        presentAsSheet(connectionViewController)
        
    }
    
    @objc func deleteConnection(_ sender: NSMenuItem) {
        
        let connectionId = Int(sender.identifier!.rawValue)
        let connection = viewModel.getConnection(connectionId: connectionId!)
        privateDB.fetch(withRecordID: connection!.id!, completionHandler: { (record, error) in
            if let returnedRecord = record {
                self.privateDB.delete(withRecordID: returnedRecord.recordID, completionHandler: { (_, error) in
                    
                    DispatchQueue.main.async {
                        if let error = error {
                            
                            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                                   message: error.localizedDescription)
                            
                        } else {
                            
                            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.informational,
                                                   message: "Connection deleted")
                            
                        }
                        
                        self.loadIcloudData()
                    }
                })
            }
        })
    }
    
    // MARK: Open and Close connections
    @IBAction func connectButtonClicked(_ sender: NSButton) {
        
        if connectionComboBox.indexOfSelectedItem == -1 {
            
            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                   message: "You need to select a connection before connecting")
            return
            
        }
        
        let connection = viewModel.connections[connectionComboBox.indexOfSelectedItem]
        
        if activeConnections[connection.connectionId] != nil {

            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                   message: "This connection is already active")
            return
                    
                }
        
        // Private key support not yet added... But we still need to check if a password is present.
        // The private key exists in the data model, so the check for both has been added.
        if connection.privateKey == "" && connection.password == "" {
            let storyboard = NSStoryboard(name: "PasswordPrompt", bundle: nil)
            let passwordPromptVcontroller = storyboard.instantiateController(withIdentifier: "PasswordPromptID")
            presentAsSheet(passwordPromptVcontroller as! NSViewController)
            return
            
        }
        
        openConnection(password: nil)
        
    }
    
    func openConnection(password: String?) {
        
        let connection = viewModel.connections[connectionComboBox.indexOfSelectedItem]
        let sshClient = SSHClient()
        let connectionRecord = TableViewConnectionRecords(connection: connection, sshClient: sshClient)
        self.activeConnections[connection.connectionId] = connectionRecord
        self.tableView.reloadData()
        
        DispatchQueue.global(qos:.userInitiated).async {
            
            do {
                
                try sshClient.Connect(connection: connection, password: password)
                
            } catch {
                
                self.activeConnections.removeValue(forKey: connection.connectionId)
                
                DispatchQueue.main.async {
                    
                    self.tableView.reloadData()
                    Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                                           message: error.localizedDescription)
                    
                }
            }
        }
    }
    
    @IBAction func closeConnection(_ sender: CloseButton) {
        
        if let activeConnection = activeConnections[sender.connectionId!] {
            if let sshClient = activeConnection.sshClient {
                sshClient.disconnect()
            }
        }
        
        activeConnections.removeValue(forKey: sender.connectionId!)
        tableView.reloadData()
        
    }
    
    @objc @IBAction func closeAllConnections(_ sender: NSMenuItem) {
        
        for connection in activeConnections {
            let sshClient = connection.value.sshClient
            sshClient?.disconnect()
            
        }
        
        activeConnections.removeAll()
        tableView.reloadData()
        
    }
    
    //MARK: Import / Export connection definitions
    @objc @IBAction func exportConnectionsToJSON(_ sender: NSMenuItem) {
        
        let jsonData = viewModel.exportConnectionsToJSON()
        
        if let documentDirectory = FileManager.default.urls(for: .documentDirectory,
                                                            in: .userDomainMask).first {
            let pathWithFileName = documentDirectory.appendingPathComponent("SSH TunnelBuilder Connections.json")
            do {
                try jsonData!.write(to: pathWithFileName,
                                    options: Data.WritingOptions.atomic)
            } catch {
                NSLog("Failed to write data to disk.")
            }
        }
    }
}

// MARK: NSTableViewDataSource extension
extension ViewController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return activeConnections.count
        
    }
}

// MARK: NSTableViewDelegate extension
extension ViewController: NSTableViewDelegate {
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        let connectionId = Array(activeConnections.keys)[row]
        let currentConnection = activeConnections[connectionId]?.connection
        
        if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "sshHostColumn") {
        
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "sshHostCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.stringValue = currentConnection?.sshHost ?? "SSH Host"
            return cellView
        
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "localPortColumn") {
        
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "localPortCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.integerValue = currentConnection?.localPort ?? 0
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "remoteServerColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "remoteServerCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.stringValue = currentConnection?.remoteServer ?? "Unknown"
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "remotePortColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "remotePortCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.integerValue = currentConnection?.remotePort ?? 0
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "closeColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "closeCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            let closeButton = cellView.nextKeyView as? CloseButton
            closeButton?.connectionId = currentConnection?.connectionId
            closeButton?.connectionName = currentConnection?.connectionName
            
            return cellView
           
       } else {
           
            NSLog("Column Identifier returned nil")
            return nil
            
        }
        
    }
}

// MARK: NSComboBoxDataSource extension
extension ViewController: NSComboBoxDataSource {
    
    func numberOfItems(in connectionComboBox: NSComboBox) -> Int {
        
        return viewModel.connections.count
        
    }
    
    func comboBox(_ connectionComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        
        return viewModel.connections[index].connectionName
        
    }
}
