//
//  ContentView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

var editmode = false
var currentDisplayedConnection = 0

struct ContentView: View {
    var body: some View {
        NavigationView {
            ListView()
            
            MainView()
        }.frame(width: 600, height: 300)
    }
}

struct ListView: View {
    var body: some View {
        VStack {
            Text("Connections").padding()
            ScrollView {
                LazyVStack {
                    // TODO: Create a ForEach-loop that will create a button for each connection
                    Button(action: populateMainView) {
                        Text("Connection 1")
                    }.padding(2)
                }
            }
            Button(action: addNewConnection) {
                Label("Add Connection", systemImage: "folder.badge.plus")
            }
        }
    }
}

struct MainView: View {
    var body: some View {
        VStack {
            Text("ConnectionName: PlaceHolder").frame(width: 200, height: 5, alignment: .top)
        }
    }
}

func populateMainView() {
    return
}

func addNewConnection() {
    return
}

func editConnection() {
    return
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
