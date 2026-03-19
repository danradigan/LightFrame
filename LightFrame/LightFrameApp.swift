import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LightFrame App Entry Point
// This is the first thing that runs when the app launches.
// We create a single AppState object here and pass it to every view
// via the environment — this means all views share the same data.
@main
struct LightFrameApp: App {

    // The single source of truth for the entire app
    @StateObject private var appState = AppState()

    // TVConnectionManager is hoisted here so menu commands can access it.
    // Previously owned by ContentView, but .commands lives at the App level.
    @StateObject private var tvManager: TVConnectionManager

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _tvManager = StateObject(wrappedValue: TVConnectionManager(appState: state))
    }

    var body: some Scene {
        // Main window
        Window("LightFrame", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(tvManager)
                // Set a sensible minimum window size
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowFrameAutosave())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // MARK: File Menu
            CommandGroup(replacing: .newItem) {
                Button("Export Sync Report...") {
                    exportSyncReport()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.selectedTV == nil)

                Divider()

                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // MARK: View Menu
            CommandMenu("View") {
                Button("All Photos") {
                    appState.gridFilter = .all
                    appState.clearSelection()
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("On TV") {
                    appState.gridFilter = .onTV
                    appState.clearSelection()
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Not on TV") {
                    appState.gridFilter = .notOnTV
                    appState.clearSelection()
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    appState.zoomIn()
                }
                .keyboardShortcut(">", modifiers: .command)

                Button("Zoom Out") {
                    appState.zoomOut()
                }
                .keyboardShortcut("<", modifiers: .command)

                Button("Actual Size") {
                    appState.zoomActualSize()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // MARK: TV Menu
            CommandMenu("TV") {
                Button("Connect") {
                    Task { await tvManager.reconnect() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(tvManager.isConnected || appState.selectedTV == nil)

                Button("Disconnect") {
                    tvManager.artService.disconnect()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!tvManager.isConnected)

                Divider()

                Button("Scan TV") {
                    appState.triggerScanTV = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appState.selectedTV == nil)

                Button("Scan Folder") {
                    Task { await appState.scanSelectedCollection() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState.selectedCollection == nil || appState.isScanning)

                Divider()

                Button("Select All") {
                    appState.selectAll(photos: appState.filteredPhotos)
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("Deselect All") {
                    appState.clearSelection()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Remove Selected from TV") {
                    appState.triggerDeleteSelected = true
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!tvManager.isConnected || (appState.selectedPhotoIDs.isEmpty && appState.selectedTVOnlyItemIDs.isEmpty))
            }

            // MARK: Help Menu
            CommandGroup(replacing: .help) {
                Button("About LightFrame") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }

        // Preferences window — opens with Cmd+,
        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }

    // MARK: - Window Frame Autosave
    /// Restores window frame before the first render and validates it's on-screen.
    /// Uses viewDidMoveToWindow (fires during window setup, before display) to
    /// avoid the flash of default-size → saved-size.
    private struct WindowFrameAutosave: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { WindowConfigView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private class WindowConfigView: NSView {
        private var configured = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window, !configured else { return }
            configured = true

            window.setFrameAutosaveName("MainWindow")

            // If the restored frame doesn't intersect any visible screen
            // (e.g. external monitor disconnected), reset to a sensible default.
            let onScreen = NSScreen.screens.contains { screen in
                screen.visibleFrame.intersects(window.frame)
            }
            if !onScreen {
                if let screen = NSScreen.main ?? NSScreen.screens.first {
                    let defaultSize = NSSize(width: 1200, height: 800)
                    let origin = NSPoint(
                        x: screen.visibleFrame.midX - defaultSize.width / 2,
                        y: screen.visibleFrame.midY - defaultSize.height / 2
                    )
                    window.setFrame(NSRect(origin: origin, size: defaultSize), display: false)
                }
            }
        }
    }

    // MARK: - Export Sync Report
    private func exportSyncReport() {
        guard let tv = appState.selectedTV else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let records = syncStore.allRecords

        // Build CSV content
        var csv = "Filename,Content ID,Uploaded At,Matte Style,Matte Color\n"
        let formatter = ISO8601DateFormatter()
        for record in records {
            let style = record.matte?.style.displayName ?? ""
            let color = record.matte.flatMap { $0.color?.displayName } ?? ""
            csv += "\(record.filename),\(record.tvContentID),\(formatter.string(from: record.uploadedAt)),\(style),\(color)\n"
        }

        // Present save panel
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SyncReport-\(tv.name).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
