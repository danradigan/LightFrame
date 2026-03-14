import SwiftUI

// MARK: - ContentView
// The main three-column layout of the app:
// [Sidebar] | [Photo Grid] | [Detail Panel]
//
// Uses NavigationSplitView which is the modern SwiftUI way to build
// multi-column Mac layouts — it handles column sizing and collapsing.
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            // Left column — collections, filters, TV controls
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)

        } content: {
            // Center column — scrollable photo grid
            PhotoGridView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)

        } detail: {
            // Right column — selected photo detail and matte editor
            DetailPanel()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        }
        // Listen for token notifications from TVConnection and save them
        .onReceive(NotificationCenter.default.publisher(for: .tvTokenReceived)) { note in
            guard let tvID = note.userInfo?["tvID"] as? UUID,
                  let token = note.userInfo?["token"] as? String,
                  let tv = appState.tvs.first(where: { $0.id == tvID })
            else { return }
            appState.updateToken(token, for: tv)
        }
    }
}
