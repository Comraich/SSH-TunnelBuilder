//
//  ConnectionViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 23/05/2021.
//

import Cocoa
import CloudKit

class ConnectionViewController: NSViewController {
    
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
    
//    required override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
//
//        super.init(nibName: nil, bundle: nil)
//    }
//
//
//
//    init(connection: Connection?) {
//
//        super.init(nibName: nil, bundle: nil)
//
//        if let connection = connection {
//
//            connectionNameField.stringValue = connection.connectionName
//            sshHostField.stringValue = connection.sshHost
//            sshHostPortField.stringValue = String(connection.sshHostPort)
//            localPortField.stringValue = String(connection.localPort)
//            remoteServerField.stringValue = connection.remoteServer
//            remotePortField.stringValue = String(connection.remotePort)
//            usernameField.stringValue = connection.userName
//            passwordField.stringValue = connection.password ?? " "
//            sshPrivateKeyField.stringValue = connection.publicKey ?? " "
//
//            commitButton.title = "Edit"
//        }
//
//    }
    
    func setConnection(connection: Connection?) {
        
        if let connection = connection {
            
            connectionNameField.stringValue = connection.connectionName
            sshHostField.stringValue = connection.sshHost
            sshHostPortField.stringValue = String(connection.sshHostPort)
            localPortField.stringValue = String(connection.localPort)
            remoteServerField.stringValue = connection.remoteServer
            remotePortField.stringValue = String(connection.remotePort)
            usernameField.stringValue = connection.userName
            passwordField.stringValue = connection.password ?? " "
            sshPrivateKeyField.stringValue = connection.publicKey ?? " "
            
            commitButton.title = "Edit"
            
        }
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
        
        
        dismissSheet()
        
    }
    
    func updateConnection(connection: Connection) {
        
    
    }
    
    @IBAction func cancelConnectionAction(_ sender: NSButton) {
      
        dismissSheet()
        
    }
    
    func dismissSheet() {
        
        let parentViewController = presentingViewController as! ViewController
                parentViewController.dismiss(self)
        
    }
}
