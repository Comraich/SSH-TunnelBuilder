//
//  ViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Cocoa

class ViewController: NSViewController {
    
    @IBOutlet var tableView: NSTableView!
    var viewModel = ViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.dataSource = self
        
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        tableView.reloadData()
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
}

extension ViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return viewModel.connections.count
    }
}

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
     
        let currentConnection = viewModel.connections[row]
        
        if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "localPortColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "localPortCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.integerValue = currentConnection.localPort ?? 0
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "remoteServerColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "remoteServerCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.stringValue = currentConnection.remoteServer ?? "Unknown"
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "remotePortColumn") {
            
            let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "remotePortCell")
            guard let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView else { return nil }
            cellView.textField?.integerValue = currentConnection.remotePort ?? 0
            return cellView
            
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier(rawValue: "closeColumn") {
            
        } else {
            
            NSLog("Column Identifier returned nil")
            return nil
        }
        
        return nil
    }
}
