import Foundation
import SwiftUI
import Combine

// MARK: - TVConnectionManager
// Manages the active WebSocket connection to the selected TV.
// Automatically connects when the selected TV changes.
// Updates AppState reachability so the green dot reflects real connection state.
@MainActor
class TVConnectionManager: ObservableObject {

    @Published var connection: TVConnection?
    @Published var statusMessage: String = ""

    // Track current slideshow settings so we can always send both
    // duration and type together in one set_slideshow_status call.
    // The Python library requires both in a single request — sending them
    // separately causes each call to overwrite the other's setting.
    @Published var currentSlideshowOrder: SlideshowOrder       = .random
    @Published var currentSlideshowInterval: SlideshowInterval = .fifteenMinutes

    private var connectedTVID: UUID? = nil
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init(appState: AppState) {
        self.appState = appState
        observeSelectedTV()
    }

    // MARK: - Observe Selected TV
    // Maps to UUID before removeDuplicates() so reachability updates
    // (which change tv.isReachable but not tv.id) don't trigger reconnects.
    private func observeSelectedTV() {
        appState.$selectedTV
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] tvID in
                guard let self else { return }
                Task { @MainActor in
                    let tv = self.appState.tvs.first(where: { $0.id == tvID })
                    await self.switchTo(tv: tv)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Switch TV
    private func switchTo(tv: TV?) async {
        let incomingID = tv?.id
        guard incomingID != connectedTVID else { return }
        connectedTVID = incomingID

        connection?.disconnect()
        connection = nil

        guard let tv else {
            statusMessage = ""
            return
        }

        let newConnection = TVConnection(tv: tv)
        connection = newConnection

        newConnection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let reachable = state == .connected
                self.appState.updateReachability(reachable, for: tv)
                switch state {
                case .connected:
                    self.statusMessage = "Connected to \(tv.name)"
                case .connecting:
                    self.statusMessage = "Connecting to \(tv.name)..."
                case .disconnected:
                    if self.connectedTVID == tv.id {
                        self.statusMessage = "\(tv.name) — Disconnected"
                    }
                case .error(let msg):
                    self.statusMessage = "Error: \(msg)"
                }
            }
            .store(in: &cancellables)

        statusMessage = "Connecting to \(tv.name)..."
        await newConnection.connect()

        // After connecting, read the TV's current slideshow status
        // so the footer controls reflect reality
        if newConnection.state == .connected {
            await readSlideshowStatus()
        }
    }

    // MARK: - Manual Reconnect
    func reconnect() async {
        connectedTVID = nil
        if let tv = appState.selectedTV {
            await switchTo(tv: tv)
        }
    }

    // MARK: - Slideshow
    // Both order and interval must be sent together in one set_slideshow_status call.
    // We track both values here so changing one still sends the other correctly.

    /// Reads the TV's current slideshow settings and updates our local tracking.
    /// Called once after connecting so the footer controls match reality.
    func readSlideshowStatus() async {
        guard let conn = connection, conn.state == .connected else { return }
        do {
            if let status = try await conn.getParsedSlideshowStatus() {
                // Parse interval from value string (e.g. "15" → .fifteenMinutes, "off" → default)
                if let minutes = Int(status.value),
                   let interval = SlideshowInterval(rawValue: minutes) {
                    currentSlideshowInterval = interval
                } else {
                    // "off" or empty — keep the default
                }
                // Parse order from type string
                if status.type == "shuffleslideshow" {
                    currentSlideshowOrder = .random
                } else if status.type == "slideshow" {
                    currentSlideshowOrder = .inOrder
                }
                print("📺 Slideshow synced: interval=\(currentSlideshowInterval.displayName) order=\(currentSlideshowOrder.displayName)")
            }
        } catch {
            print("📺 Could not read slideshow status: \(error.localizedDescription)")
        }
    }

    func setSlideshowOrder(_ order: SlideshowOrder) async -> Bool {
        currentSlideshowOrder = order
        return await applySlideshowStatus()
    }

    func setSlideshowInterval(_ interval: SlideshowInterval) async -> Bool {
        currentSlideshowInterval = interval
        return await applySlideshowStatus()
    }

    private func applySlideshowStatus() async -> Bool {
        guard let conn = connection, conn.state == .connected else { return false }
        do {
            try await conn.setSlideshowStatus(
                order:    currentSlideshowOrder,
                interval: currentSlideshowInterval
            )
            return true
        } catch {
            statusMessage = "Failed to set slideshow: \(error.localizedDescription)"
            return false
        }
    }
}
