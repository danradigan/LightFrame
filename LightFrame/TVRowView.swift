//
//  TVRowView.swift
//  LightFrame
//

import SwiftUI

// MARK: - TVRowView
// Shows a single TV in the sidebar with connection status,
// and a context menu for rename, protocol tests, and remove.
// Visually highlights when selected, matching the sidebar selection style.
struct TVRowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager
    let tv: TV

    @State private var isRenaming = false
    @State private var renameName = ""
    @State private var showProtocolTests = false
    @State private var showConnectionDiag = false

    var isSelected: Bool { appState.selectedTV?.id == tv.id }

    var body: some View {
        Label {
            HStack {
                Text(tv.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                Text(tv.ipAddress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } icon: {
            Circle()
                .fill(tv.isReachable ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
        .tag(tv.id)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor)
                    .padding(.horizontal, 8)
                : nil
        )
        .foregroundColor(isSelected ? .white : nil)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedTV = tv
        }
        .contextMenu {
            Button("Rename...") {
                renameName = tv.name
                isRenaming = true
            }
            Divider()
            Button("Protocol Tests...") {
                showProtocolTests = true
            }
            Button("Connection Diagnostics...") {
                showConnectionDiag = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                appState.removeTV(tv)
            }
        }
        .sheet(isPresented: $showProtocolTests) {
            ProtocolTestSheet(tv: tv, artService: tvManager.artService)
        }
        .sheet(isPresented: $showConnectionDiag) {
            ConnectionDiagnosticSheet(ipAddress: tv.ipAddress)
        }
        .alert("Rename TV", isPresented: $isRenaming) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    if let index = appState.tvs.firstIndex(where: { $0.id == tv.id }) {
                        appState.tvs[index].name = trimmed
                        if appState.selectedTV?.id == tv.id {
                            appState.selectedTV = appState.tvs[index]
                        }
                        appState.save()
                    }
                }
            }
        }
    }
}
