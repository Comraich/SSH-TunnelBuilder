//
//  Utilities.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 05/07/2021.
//

import AppKit

class Utilities
{
    static func ShowAlertBox( alertStyle: NSAlert.Style, message: String )
    {
        //DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = alertStyle
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        //}
    }
}
