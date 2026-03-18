//
//  ContentView.swift
//  WinP
//
//  Created by amania on 2026/03/18.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var client = RDPClientService()

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var fullScreen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WinP RDP Client")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Host (example: 192.168.1.10)", text: $host)
                        .textFieldStyle(.roundedBorder)

                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    TextField("Domain (optional)", text: $domain)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Full screen", isOn: $fullScreen)

                    if !fullScreen {
                        HStack {
                            TextField("Width", text: $width)
                                .textFieldStyle(.roundedBorder)
                            Text("x")
                            TextField("Height", text: $height)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            HStack {
                Button("Connect") {
                    client.connect(
                        host: host,
                        username: username,
                        password: password,
                        domain: domain.isEmpty ? nil : domain,
                        fullScreen: fullScreen,
                        width: Int(width),
                        height: Int(height)
                    )
                }
                .disabled(client.isRunning)

                Button("Disconnect") {
                    client.disconnect()
                }
                .disabled(!client.isRunning)
            }

            Text(client.statusMessage)
                .font(.subheadline)
                .foregroundStyle(client.isError ? .red : .secondary)

            GroupBox("Log") {
                ScrollView {
                    Text(client.outputLog)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 620)
    }
}

#Preview {
    ContentView()
}
