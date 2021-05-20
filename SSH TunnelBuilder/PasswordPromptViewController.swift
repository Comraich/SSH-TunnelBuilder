//
//  PasswordPromptViewController.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 20/05/2021.
//

import Cocoa

class PasswordPromptViewController: NSViewController {
    
    @IBOutlet weak var promptLabel: NSTextField!
    @IBOutlet weak var passwordTextBox: NSTextField!
    @IBOutlet weak var passwordSaveCheckbox: NSButton!
    
    @IBAction func connectButtonClicked(_ sender: NSButton!) {
        let parentViewController = presentingViewController as! ViewController
        parentViewController.dismiss(self)
        parentViewController.openConnection(password: passwordTextBox.stringValue)
        
    }
}
