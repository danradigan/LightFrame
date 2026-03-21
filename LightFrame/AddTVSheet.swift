//
//  AddTVSheet.swift
//  LightFrame
//
//  Created by Dan Radigan on 3/14/26.
//


import SwiftUI

// MARK: - AddTVSheet
// Modal for adding a new TV. Supports both manual IP entry
// and automatic discovery via SSDP on the local network.
struct AddTVSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var ipAddress: String = ""
    @State private var showConnectionDiag = false
    @StateObject private var discovery = TVDiscovery()

    var canSave: Bool { !name.isEmpty && !ipAddress.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header
            Text("Add TV")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Discovery Section
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Discover on Network")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Button {
                                Task { await discovery.startSearch() }
                            } label: {
                                if discovery.isSearching {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.7)
                                        Text("Scanning…")
                                    }
                                } else {
                                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                                }
                            }
                            .disabled(discovery.isSearching)
                        }

                        if discovery.discoveredTVs.isEmpty && !discovery.isSearching {
                            Text("Tap Scan to search for Samsung Frame TVs on your network.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // List of discovered TVs
                        ForEach(discovery.discoveredTVs) { discovered in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(discovered.name)
                                        .font(.subheadline)
                                    Text("\(discovered.ipAddress) · \(discovered.modelName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Select") {
                                    // Auto-fill the form fields
                                    name = discovered.name
                                    ipAddress = discovered.ipAddress
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }

                    Divider()

                    // MARK: Manual Entry Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Manual Entry")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. Living Room", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("IP Address")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("e.g. 192.168.86.25", text: $ipAddress)
                                .textFieldStyle(.roundedBorder)
                            Text("Set a static IP on your TV for a reliable connection.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            // MARK: Buttons
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Diagnose Connection...") {
                    showConnectionDiag = true
                }
                .disabled(ipAddress.isEmpty)
                Button("Add TV") {
                    appState.addTV(name: name, ipAddress: ipAddress)
                    dismiss()
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .frame(width: 380, height: 500)
        .sheet(isPresented: $showConnectionDiag) {
            ConnectionDiagnosticSheet(ipAddress: ipAddress)
        }
    }
}