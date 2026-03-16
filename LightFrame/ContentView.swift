import SwiftUI

// MARK: - ContentView
// Main three-column layout with a footer bar containing slideshow controls.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var tvManager: TVConnectionManager

    // Toast confirmation state
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false

    init(appState: AppState) {
        _tvManager = StateObject(wrappedValue: TVConnectionManager(appState: appState))
    }

    var isConnected: Bool {
        tvManager.isConnected
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
                            .fill(isConnected ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(isConnected ? tv.name : "\(tv.name) — Offline")
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
                    Picker("", selection: $tvManager.currentSlideshowOrder) {
                        ForEach(SlideshowOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .disabled(!isConnected)
                    .onChange(of: tvManager.currentSlideshowOrder) {
                        Task {
                            let success = await tvManager.setSlideshowOrder(tvManager.currentSlideshowOrder)
                            if success { showConfirmation("Order set to \(tvManager.currentSlideshowOrder.displayName)") }
                        }
                    }

                    // Interval picker
                    Picker("", selection: $tvManager.currentSlideshowInterval) {
                        ForEach(SlideshowInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .frame(width: 120)
                    .disabled(!isConnected)
                    .onChange(of: tvManager.currentSlideshowInterval) {
                        Task {
                            let success = await tvManager.setSlideshowInterval(tvManager.currentSlideshowInterval)
                            if success { showConfirmation("Interval set to \(tvManager.currentSlideshowInterval.displayName)") }
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
