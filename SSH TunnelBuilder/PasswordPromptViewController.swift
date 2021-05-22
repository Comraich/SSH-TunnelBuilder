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
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        passwordTextBox.delegate = self
    }
    
    @IBAction func connectButtonClicked(_ sender: NSButton!) {
        
        self.sendPasswordAndConnect()
        
    }
    
    func sendPasswordAndConnect() {
        
        let parentViewController = presentingViewController as! ViewController
        parentViewController.dismiss(self)
        parentViewController.openConnection(password: passwordTextBox.stringValue)
        
    }
}

extension PasswordPromptViewController: NSTextFieldDelegate {
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if (commandSelector == #selector(NSResponder.insertNewline(_:))) {
            
            self.sendPasswordAndConnect()
            
        }
        
        return true
        
    }
}
