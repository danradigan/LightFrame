import SwiftUI

// MARK: - ContentView
// Main three-column layout with a footer bar containing slideshow controls.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    // Sidebar visibility — persisted via AppStorage
    @AppStorage("sidebarVisibility") private var savedVisibility: String = "all"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Toast confirmation state
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false

    var isConnected: Bool {
        tvManager.isConnected
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            PhotoGridView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footerBar
                }
        } detail: {
            DetailPanel()
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 580)
        }
        .environmentObject(tvManager)
        .onAppear {
            switch savedVisibility {
            case "detailOnly": columnVisibility = .detailOnly
            case "doubleColumn": columnVisibility = .doubleColumn
            default: columnVisibility = .all
            }
        }
        .onChange(of: columnVisibility) {
            switch columnVisibility {
            case .detailOnly: savedVisibility = "detailOnly"
            case .doubleColumn: savedVisibility = "doubleColumn"
            default: savedVisibility = "all"
            }
        }
    }

    // MARK: - Footer Bar
    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                // Status text
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                // Thumbnail size slider
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Slider(value: $appState.thumbnailSize, in: 80...280)
                        .frame(width: 100)
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()
                    .frame(height: 16)

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
                        guard !tvManager.isSyncingSlideshow else { return }
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
                        guard !tvManager.isSyncingSlideshow else { return }
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
            .background(.bar)
        }
    }

    private var statusText: String {
        var parts: [String] = []
        parts.append(appState.currentSelectionName)

        let total = appState.filteredPhotos.count
        parts.append("\(total) photo\(total == 1 ? "" : "s")")

        let selected = appState.selectedPhotoIDs.count + appState.selectedTVOnlyItemIDs.count
        if selected > 0 { parts.append("\(selected) selected") }

        if let tv = appState.selectedTV {
            let isReachable = appState.tvs.first(where: { $0.id == tv.id })?.isReachable ?? false
            parts.append(isReachable ? tv.name : "\(tv.name) (offline)")
        }

        return parts.joined(separator: " \u{00B7} ")
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
