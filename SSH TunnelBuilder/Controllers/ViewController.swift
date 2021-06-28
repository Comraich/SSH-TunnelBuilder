//
//  ViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Cocoa
import AppKit
import CloudKit

class ViewController: NSViewController, NSComboBoxDataSource {
    
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
        refresh()
        tableView.reloadData()
        connectionComboBox.reloadData()
        
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        // Make the main window non-resizable
        self.view.window?.styleMask.remove(NSWindow.StyleMask.resizable)
        self.view.window?.title = "SSH TunnelBuilder"
        

    }

    @objc func refresh() {
        
        if (self.connectionComboBox.indexOfSelectedItem != -1) {

            self.connectionComboBox.deselectItem(at: self.connectionComboBox.indexOfSelectedItem)

        }
        self.connectionComboBox.stringValue = ""
        
        viewModel.refresh { error in
            if let error = error {
                let alert = NSAlert()
                alert.messageText = error.localizedDescription
                alert.alertStyle = NSAlert.Style.critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
                
            } else {
                
                self.setupMenus()
                
                DispatchQueue.main.async {
                    
                    if self.numberOfItems(in: self.connectionComboBox) == 0 {
                        let alert = NSAlert()
                        alert.messageText = "You do not have any connections defined. Go to File -> Create new connection or File -> Import connections to get started."
                        alert.alertStyle = NSAlert.Style.informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        
                    }
                }
            }
        }
        
        tableView.reloadData()
        
    }
    
    override var representedObject: Any? {
        didSet {
            
            tableView.reloadData()
            connectionComboBox.reloadData()
            
        }
    }
    @objc func presentNewConnectionSheet(_ sender: NSMenuItem) {
        
        let storyboard = NSStoryboard(name: "Connection", bundle: nil)
        let newConnectionViewController = storyboard.instantiateController(withIdentifier: "ConnectionPromptId")
        presentAsSheet(newConnectionViewController as! ConnectionViewController)
        
    }
    
    @objc func presentEditConnectionSheet(_ sender: NSMenuItem) {
        
        let connectionId = Int(sender.identifier!.rawValue)
        let storyboard = NSStoryboard(name: "Connection", bundle: nil)
        let editConnectionViewController = storyboard.instantiateController(withIdentifier: "ConnectionPromptId") as! ConnectionViewController
        let connection = viewModel.getConnection(connectionId: connectionId!)
        editConnectionViewController.setConnection(connection: connection)
        presentAsSheet(editConnectionViewController)
        
    }
    
    @objc func deleteConnection(_ sender: NSMenuItem) {
        
        let connectionId = Int(sender.identifier!.rawValue)
        let connection = viewModel.getConnection(connectionId: connectionId!)
        privateDB.fetch(withRecordID: connection!.id!, completionHandler: { (record, error) in
            if let returnedRecord = record {
                self.privateDB.delete(withRecordID: returnedRecord.recordID, completionHandler: { (recordID, error) in
                    
                    DispatchQueue.main.async {
                        
                        if let error = error {
                            
                            let alert = NSAlert()
                            alert.messageText = error.localizedDescription
                            alert.alertStyle = NSAlert.Style.critical
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                            
                        } else {
                            
                            let alert = NSAlert()
                            alert.messageText = "Connection deleted"
                            alert.alertStyle = NSAlert.Style.informational
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                            
                        }
                        
                        self.refresh()
                        
                    }
                })
            }
        })
    }
    

    
    func numberOfItems(in connectionComboBox: NSComboBox) -> Int {
        
        return viewModel.connections.count
        
    }
    
    func comboBox(_ connectionComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        
        return viewModel.connections[index].connectionName
        
    }
    
    @IBAction func connectButtonClicked(_ sender: NSButton) {
        
        if connectionComboBox.indexOfSelectedItem == -1 {
            
            let alert = NSAlert()
                        alert.messageText = "You need to select a connection before connecting"
                        alert.alertStyle = NSAlert.Style.critical
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                        return
            
        }
        
        let connection = viewModel.connections[connectionComboBox.indexOfSelectedItem]
        
        if activeConnections[connection.connectionId] != nil {
                    let alert = NSAlert()
                                alert.messageText = "This connection is already active"
                                alert.alertStyle = NSAlert.Style.critical
                                alert.addButton(withTitle: "OK")
                                alert.runModal()
                                return
                    
                }
        
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
        
        DispatchQueue.global(qos:.userInitiated).async {
            
            do {
                try sshClient.Connect(connection: connection, password: password)
            } catch {
                NSLog("Exception thrown: \(error)")
            }
        }
        
        let connectionRecord = TableViewConnectionRecords(connection: connection, sshClient: sshClient)
        activeConnections[connection.connectionId] = connectionRecord
        tableView.reloadData()
        
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
    
    func checkIcloudAccountStatus() {
        
        CKContainer.default().accountStatus { accountStatus, error in
            if accountStatus == .noAccount {
                DispatchQueue.main.async {
                    let message = "This app uses iCloud to store your connection settings. Please sign in to iCloud in System Preferences."
                    let alert = NSAlert()
                    alert.alertStyle = NSAlert.Style.critical
                    alert.messageText = message
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                    
                }
            }
        }
    }
    
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
    
}

extension ViewController: NSTableViewDataSource {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return activeConnections.count
        
    }
}

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
