import SwiftUI

// MARK: - ContentView
// Main three-column layout with a footer bar containing slideshow controls.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var tvManager: TVConnectionManager

    // Toast confirmation state
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false

    @State private var slideshowOrder: SlideshowOrder = .random
    @State private var slideshowInterval: SlideshowInterval = .fifteenMinutes

    init(appState: AppState) {
        _tvManager = StateObject(wrappedValue: TVConnectionManager(appState: appState))
    }

    var isConnected: Bool {
        appState.selectedTV?.isReachable ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Main Three-Column Layout
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } content: {
                PhotoGridView()
                    .navigationSplitViewColumnWidth(min: 400, ideal: 600)
            } detail: {
                DetailPanel()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 580)
            }
            .environmentObject(tvManager)

            Divider()

            // MARK: Footer Bar — Slideshow Controls
            HStack(spacing: 16) {
                // TV status
                if let tv = appState.selectedTV {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tv.isReachable ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(tv.isReachable ? tv.name : "\(tv.name) — Offline")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Slideshow controls — greyed when offline
                HStack(spacing: 12) {
                    Text("Slideshow:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Order toggle
                    Picker("", selection: $slideshowOrder) {
                        ForEach(SlideshowOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .disabled(!isConnected)
                    .onChange(of: slideshowOrder) {
                        Task {
                            let success = await tvManager.setSlideshowOrder(slideshowOrder)
                            if success { showConfirmation("Order set to \(slideshowOrder.displayName)") }
                        }
                    }

                    // Interval picker
                    Picker("", selection: $slideshowInterval) {
                        ForEach(SlideshowInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .frame(width: 120)
                    .disabled(!isConnected)
                    .onChange(of: slideshowInterval) {
                        Task {
                            let success = await tvManager.setSlideshowInterval(slideshowInterval)
                            if success { showConfirmation("Interval set to \(slideshowInterval.displayName)") }
                        }
                    }
                }
                .opacity(isConnected ? 1.0 : 0.4)

                // Toast confirmation
                if showToast {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(toastMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        // Listen for token notifications from TVConnection
        .onReceive(NotificationCenter.default.publisher(for: .tvTokenReceived)) { note in
            guard let tvID = note.userInfo?["tvID"] as? UUID,
                  let token = note.userInfo?["token"] as? String,
                  let tv = appState.tvs.first(where: { $0.id == tvID })
            else { return }
            appState.updateToken(token, for: tv)
        }
    }

    private func showConfirmation(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { showToast = false }
        }
    }
}
