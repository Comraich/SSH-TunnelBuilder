//
//  ConnectionViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 23/05/2021.
//

import Cocoa
import CloudKit

class ConnectionViewController: NSViewController {
    
    @IBOutlet var titleLabel: NSTextField!
    @IBOutlet var connectionNameField: NSTextField!
    @IBOutlet var sshHostField: NSTextField!
    @IBOutlet var sshHostPortField: NSTextField!
    @IBOutlet var localPortField: NSTextField!
    @IBOutlet var remoteServerField: NSTextField!
    @IBOutlet var remotePortField: NSTextField!
    @IBOutlet var usernameField: NSTextField!
    @IBOutlet var passwordField: NSTextField!
    @IBOutlet var sshPrivateKeyField: NSTextField!
    @IBOutlet var commitButton: NSButton!
    var connection: Connection?
    let privateDB = CKContainer.default().privateCloudDatabase
    
    override func viewDidLoad() {
        
        if let connection = connection {
        
            connectionNameField.stringValue = connection.connectionName
            sshHostField.stringValue = connection.sshHost
            sshHostPortField.stringValue = String(connection.sshHostPort)
            localPortField.stringValue = String(connection.localPort)
            remoteServerField.stringValue = connection.remoteServer
            remotePortField.stringValue = String(connection.remotePort)
            usernameField.stringValue = connection.username
            passwordField.stringValue = connection.password ?? ""
            sshPrivateKeyField.stringValue = connection.privateKey ?? ""
            
            commitButton.title = "Edit"
            titleLabel.stringValue = "Edit connection"
            
        }
    }
    
    func setConnection(connection: Connection?) {
        
        self.connection = connection
        
    }
    
    @IBAction func commitButtonWasClicked(_ sender: NSButton) {
        
        if sender.title == "Add" {
            
            self.createNewConnection()
            
        } else if sender.title == "Edit" {
            
            self.updateConnection(connection: connection!)
        }
    }
    
    func createNewConnection() {
        
        NSLog("Add Connection button was clicked.")
        let record = CKRecord(recordType: "Connection")
        
        record.setValue(connectionNameField.stringValue, forKey: "connectionName")
        record.setValue(sshHostField.stringValue, forKey: "sshHost")
        record.setValue(sshHostPortField.intValue, forKey: "sshHostPort")
        record.setValue(localPortField.intValue, forKey: "localPort")
        record.setValue(remoteServerField.stringValue, forKey: "remoteServer")
        record.setValue(remotePortField.intValue, forKey: "remotePort")
        record.setValue(usernameField.stringValue, forKey: "username")
        record.setValue(passwordField.stringValue, forKey: "password")
        record.setValue(sshPrivateKeyField.stringValue, forKey: "privateKey")
        record.setValue(Int(ViewModel.highestConnectionId + 1), forKey: "connectionId")
        
        privateDB.save(record) { (saveRecord, error) in
            if error == nil {
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "New connection saved to iCloud"
                    alert.alertStyle = NSAlert.Style.informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    self.dismissSheet()
                }
                
            } else {
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = error!.localizedDescription
                    alert.alertStyle = NSAlert.Style.critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    func updateConnection(connection: Connection) {
        
        NSLog("Edit Connection button was clicked.")
        
        connection.connectionName = self.connectionNameField.stringValue
        connection.sshHost = self.sshHostField.stringValue
        connection.sshHostPort = Int(self.sshHostPortField.intValue)
        connection.localPort = Int(self.localPortField.intValue)
        connection.remoteServer = self.remoteServerField.stringValue
        connection.remotePort = Int(self.remotePortField.intValue)
        connection.username = self.usernameField.stringValue
        connection.password = self.passwordField.stringValue
        connection.privateKey = self.sshPrivateKeyField.stringValue
        
        privateDB.fetch(withRecordID: connection.id!, completionHandler: { (record, error) in
            if let record = record {
                record.setValue(connection.connectionName, forKey: "connectionName")
                record.setValue(connection.sshHost, forKey: "sshHost")
                record.setValue(connection.sshHostPort, forKey: "sshHostPort")
                record.setValue(connection.localPort, forKey: "localPort")
                record.setValue(connection.remoteServer, forKey: "remoteServer")
                record.setValue(connection.remotePort, forKey: "remotePort")
                record.setValue(connection.username, forKey: "username")
                record.setValue(connection.password, forKey: "password")
                record.setValue(connection.privateKey, forKey: "privateKey")
                record.setValue(connection.connectionId, forKey: "connectionId")
                
                self.privateDB.save(record) { (saveRecord, error) in
                    if error == nil {
                        
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Connection changes saved to iCloud"
                            alert.alertStyle = NSAlert.Style.informational
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                            self.dismissSheet()
                        }
                        
                    } else {
                        
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = error!.localizedDescription
                            alert.alertStyle = NSAlert.Style.critical
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
            }
        })
    }
    
    @IBAction func cancelConnectionAction(_ sender: NSButton) {
      
        dismissSheet()
        
    }
    
    func dismissSheet() {
        
        let parentViewController = presentingViewController as! ViewController
                parentViewController.dismiss(self)
        
    }
}
