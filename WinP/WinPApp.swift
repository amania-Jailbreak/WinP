//
//  WinPApp.swift
//  WinP
//
//  Created by amania on 2026/03/18.
//

import SwiftUI

@main
struct WinPApp: App {
    @StateObject private var client = RDPClientService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
        .defaultSize(width: 760, height: 820)
        .windowResizability(.contentSize)
    }
}
