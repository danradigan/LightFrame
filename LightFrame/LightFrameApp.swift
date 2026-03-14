import SwiftUI

// MARK: - LightFrame App Entry Point
// This is the first thing that runs when the app launches.
// We create a single AppState object here and pass it to every view
// via the environment — this means all views share the same data.
@main
struct LightFrameApp: App {

    // The single source of truth for the entire app
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView(appState: appState)
                .environmentObject(appState)
                // Set a sensible minimum window size
                .frame(minWidth: 900, minHeight: 600)
        }
        // Give the window a fixed title
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Add standard Edit menu commands
            CommandGroup(replacing: .newItem) {}
        }

        // Preferences window — opens with Cmd+,
        Settings {
            PreferencesView()
                .environmentObject(appState)
        }
    }
}
