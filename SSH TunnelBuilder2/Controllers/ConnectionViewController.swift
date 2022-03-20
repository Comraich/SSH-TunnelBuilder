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
    // @IBOutlet var sshPrivateKeyField: NSTextField! // To be implemented in a future version
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
            // sshPrivateKeyField.stringValue = connection.privateKey ?? ""
            
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
        
        let record = CKRecord(recordType: "Connection")
        
        record.setValue(connectionNameField.stringValue, forKey: "connectionName")
        record.setValue(sshHostField.stringValue, forKey: "sshHost")
        record.setValue(sshHostPortField.intValue, forKey: "sshHostPort")
        record.setValue(localPortField.intValue, forKey: "localPort")
        record.setValue(remoteServerField.stringValue, forKey: "remoteServer")
        record.setValue(remotePortField.intValue, forKey: "remotePort")
        record.setValue(usernameField.stringValue, forKey: "username")
        record.setValue(passwordField.stringValue, forKey: "password")
        // record.setValue(sshPrivateKeyField.stringValue, forKey: "privateKey")
        record.setValue(Int(ViewModel.highestConnectionId + 1), forKey: "connectionId")
        
        privateDB.save(record) { (_, error) in
            
            DispatchQueue.main.async {
                
                let parentViewController = self.presentingViewController as! ViewController

                if error == nil {
                    
                    Utilities.ShowAlertBox(alertStyle: NSAlert.Style.informational,
                                           message: "New connection saved to iCloud")
                    parentViewController.loadIcloudData()
                    self.dismissSheet()
                    
                } else {
                    
                    Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                           message: error!.localizedDescription)
                    parentViewController.loadIcloudData()
                    
                }
            }
        }
    }
    
    func updateConnection(connection: Connection) {
        
        connection.connectionName = self.connectionNameField.stringValue
        connection.sshHost = self.sshHostField.stringValue
        connection.sshHostPort = Int(self.sshHostPortField.intValue)
        connection.localPort = Int(self.localPortField.intValue)
        connection.remoteServer = self.remoteServerField.stringValue
        connection.remotePort = Int(self.remotePortField.intValue)
        connection.username = self.usernameField.stringValue
        connection.password = self.passwordField.stringValue
        // connection.privateKey = self.sshPrivateKeyField.stringValue
        
        privateDB.fetch(withRecordID: connection.id!, completionHandler: { (record, error) in
            if let returnedRecord = record {
                returnedRecord.setValue(connection.connectionName, forKey: "connectionName")
                returnedRecord.setValue(connection.sshHost, forKey: "sshHost")
                returnedRecord.setValue(connection.sshHostPort, forKey: "sshHostPort")
                returnedRecord.setValue(connection.localPort, forKey: "localPort")
                returnedRecord.setValue(connection.remoteServer, forKey: "remoteServer")
                returnedRecord.setValue(connection.remotePort, forKey: "remotePort")
                returnedRecord.setValue(connection.username, forKey: "username")
                returnedRecord.setValue(connection.password, forKey: "password")
                // returnedRecord.setValue(connection.privateKey, forKey: "privateKey")
                returnedRecord.setValue(connection.connectionId, forKey: "connectionId")
                
                self.privateDB.save(returnedRecord) { (savedRecord, error) in
                    
                    DispatchQueue.main.async {
                        
                        let parentViewController = self.presentingViewController as! ViewController
                        
                        if error == nil {
                            
                            let connectionName = savedRecord?.value(forKey: "connectionName")
                            
                            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.informational,
                                                   message: "Updated connection \(connectionName!) saved to iCloud")
                            parentViewController.loadIcloudData()
                            self.dismissSheet()
                            
                        } else {
                            
                            Utilities.ShowAlertBox(alertStyle: NSAlert.Style.critical,
                                                   message: error!.localizedDescription)
                            parentViewController.loadIcloudData()
                            
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
        
        DispatchQueue.main.async {
            
            let parentViewController = self.presentingViewController as! ViewController
            parentViewController.dismiss(self)
            
        }
    }
}
