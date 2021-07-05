//
//  ViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Cocoa

class ViewController: NSViewController, NSComboBoxDataSource {
    
    @IBOutlet var tableView: NSTableView!
    @IBOutlet weak var connectionComboBox: NSComboBox!
    var viewModel = ViewModel()
    var activeConnections = Dictionary<Int, TableViewConnectionRecords>()
    
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
        tableView.reloadData()
        connectionComboBox.reloadData()
        
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        // Make the main window non-resizable
        self.view.window?.styleMask.remove(NSWindow.StyleMask.resizable)
        self.view.window?.title = "SSH TunnelBuilder"
    }

    override var representedObject: Any? {
        didSet {
            tableView.reloadData()
        }
    }
    
    func numberOfItems(in connectionComboBox: NSComboBox) -> Int {
        
        return viewModel.connections.count
        
    }
    
    func comboBox(_ connectionComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        
        return viewModel.connections[index].connectionName
        
    }
    
    @IBAction func connectButtonClicked(_ sender: NSButton) {
        
        NSLog("Connect button was clicked in winkel. It makes sense if you know norwegian")
        let connection = viewModel.connections[connectionComboBox.indexOfSelectedItem]
        
        if connection.publicKey == "" && connection.password == "" {
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
            } catch {}
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