//
//  TVRowView.swift
//  LightFrame
//
//  Created by Dan Radigan on 3/14/26.
//


import SwiftUI

// MARK: - TVRowView
// Shows a single TV in the sidebar with connection status,
// and a context menu for rename and remove actions.
struct TVRowView: View {
    @EnvironmentObject var appState: AppState
    let tv: TV

    @State private var isRenaming = false
    @State private var renameName = ""

    var isSelected: Bool { appState.selectedTV?.id == tv.id }

    var body: some View {
        HStack(spacing: 8) {
            // Green = reachable, grey = offline
            Circle()
                .fill(tv.isReachable ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(tv.name)
                .fontWeight(isSelected ? .semibold : .regular)

            Spacer()

            Text(tv.ipAddress)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedTV = tv
        }
        .contextMenu {
            Button("Rename…") {
                renameName = tv.name
                isRenaming = true
            }
            Divider()
            Button("Remove", role: .destructive) {
                appState.removeTV(tv)
            }
        }
        .alert("Rename TV", isPresented: $isRenaming) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    // Find and update the TV in appState
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