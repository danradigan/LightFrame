import Foundation
import SwiftUI
import Combine

// MARK: - TVConnectionManager
//
// Manages the active connection to the selected TV.
//
// SamsungArtService is the SOLE connection path.
// Legacy TVConnection has been removed — all callers go through
// tvManager wrapper methods which delegate to artService.
//
@MainActor
class TVConnectionManager: ObservableObject {

    // MARK: - Published State
    @Published var statusMessage: String = ""

    // Protocol layer — the only connection path
    @Published var artService: SamsungArtService

    // Slideshow tracking
    @Published var currentSlideshowOrder: SlideshowOrder       = .random
    @Published var currentSlideshowInterval: SlideshowInterval = .fifteenMinutes

    // MARK: - Private
    private var connectedTVID: UUID? = nil
    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var reconnectTask: Task<Void, Never>? = nil
    private var reconnectAttempts: Int = 0
    private static let maxReconnectAttempts = 5

    // MARK: - Computed
    var isConnected: Bool {
        artService.isConnected
    }

    // MARK: - Init
    init(appState: AppState) {
        self.appState = appState
        self.artService = SamsungArtService()
        observeSelectedTV()
        observeArtServiceState()
    }

    // MARK: - Observe Selected TV
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

    // MARK: - Observe Art Service State
    //
    // Keeps the green dot and footer controls in sync with the protocol layer.
    // artService.$connectionState fires immediately on connect/disconnect,
    // so the UI updates without any manual call to updateReachability.
    //
    private func observeArtServiceState() {
        artService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self,
                      let tvID = self.connectedTVID,
                      let tv = self.appState.tvs.first(where: { $0.id == tvID })
                else { return }
                let reachable = state == .connected
                self.appState.updateReachability(reachable, for: tv)
            }
            .store(in: &cancellables)
    }

    // MARK: - Switch TV
    private func switchTo(tv: TV?) async {
        let incomingID = tv?.id
        guard incomingID != connectedTVID else { return }
        connectedTVID = incomingID

        // Cancel any pending reconnect
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0

        // Disconnect old
        artService.disconnect()

        guard let tv else {
            statusMessage = ""
            return
        }

        // ── Configure and connect ─────────────────────────────────────────
        artService.configure(host: tv.ipAddress, port: 8002, token: tv.token)
        artService.logHandler = { line in
            #if DEBUG
            print(line)
            #endif
        }

        statusMessage = "Connecting to \(tv.name)..."

        do {
            try await artService.connect()

            // Update token if the new layer obtained one
            if let newToken = artService.token, newToken != tv.token {
                appState.updateToken(newToken, for: tv)
            }

            statusMessage = "Connected to \(tv.name)"
            reconnectAttempts = 0

            // Read slideshow status
            await readSlideshowStatus()

        } catch {
            let msg = error.localizedDescription
            print("⚠️ Connect failed: \(msg)")
            statusMessage = "Error: \(msg)"
            scheduleReconnect(for: tv)
        }
    }

    // MARK: - Manual Reconnect
    func reconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        connectedTVID = nil
        if let tv = appState.selectedTV {
            await switchTo(tv: tv)
        }
    }

    // MARK: - Auto-Reconnect
    private func scheduleReconnect(for tv: TV) {
        reconnectTask?.cancel()
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            statusMessage = "\(tv.name) — Offline (gave up after \(Self.maxReconnectAttempts) attempts)"
            print("🔄 Gave up reconnecting to \(tv.name)")
            return
        }

        let delay = UInt64(5 * pow(2.0, Double(reconnectAttempts))) * 1_000_000_000
        reconnectAttempts += 1
        let attempt = reconnectAttempts

        print("🔄 Reconnect attempt \(attempt) in \(delay / 1_000_000_000)s...")
        statusMessage = "\(tv.name) — Reconnecting (\(attempt)/\(Self.maxReconnectAttempts))..."

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.connectedTVID == tv.id else { return }
            self.connectedTVID = nil
            await self.switchTo(tv: tv)
        }
    }

    // MARK: - API Methods
    //
    // These delegate to SamsungArtService. All callers in DetailPanel,
    // PhotoGridView, and UploadEngine use these wrapper methods.
    //

    func deletePhotos(contentIDs: [String]) async throws {
        try await artService.deleteArt(contentIDs: contentIDs)
    }

    func selectPhoto(contentID: String) async throws {
        try await artService.selectImage(contentID: contentID)
    }

    func changeMatte(contentID: String, matte: Matte) async throws {
        let matteToken = matte.apiToken
        if matte.style != .none {
            // Send two separate change_matte calls to set both slots.
            // The TV has independent matte_id (landscape) and portrait_matte_id (portrait) slots.
            // A single change_matte only writes portrait_matte_id; sending matte_id alone
            // writes to the landscape slot.
            //
            // Call 1: matte_id (landscape slot) — must succeed
            try await artService.changeMatteRaw(
                contentID: contentID,
                extraParams: ["matte_id": matteToken]
            )
            // Call 2: portrait_matte_id (portrait slot) — best effort
            // Some styles (modern, modernthin, modernwide) error -7 on portrait_matte_id
            // for certain resolutions. This is a TV firmware limitation, not a real failure.
            // The image will render correctly from matte_id for landscape images.
            do {
                try await artService.changeMatteRaw(
                    contentID: contentID,
                    extraParams: ["portrait_matte_id": matteToken]
                )
            } catch {
                artService.logHandler?("[Matte] portrait_matte_id failed (non-fatal): \(error.localizedDescription)")
            }
        } else {
            // For "none", send matte_id only
            try await artService.changeMatteRaw(
                contentID: contentID,
                extraParams: ["matte_id": matteToken]
            )
        }
    }

    func getMyPhotos() async throws -> [TVArtItem] {
        try await artService.fetchMyPhotos()
    }

    func getAvailableArt(category: String? = nil) async throws -> [TVArtItem] {
        try await artService.fetchArtList(category: category)
    }

    func getThumbnails(contentIDs: [String]) async throws -> [String: Data] {
        try await artService.fetchThumbnails(contentIDs: contentIDs)
    }

    func uploadPhoto(imageData: Data, fileType: String, matte: Matte?) async throws -> String {
        let matteToken = matte?.apiToken ?? "flexible_warm"
        let portraitToken = matte?.apiToken ?? "flexible_warm"
        return try await artService.uploadArt(
            imageData: imageData,
            fileType: fileType,
            matteID: matteToken,
            portraitMatteID: portraitToken
        )
    }

    func getCurrentArtwork() async throws -> String? {
        let inner = try await artService.fetchCurrentArtwork()
        return inner.raw["content_id"] as? String
    }

    // MARK: - Slideshow

    func readSlideshowStatus() async {
        do {
            let status = try await artService.fetchSlideshowStatus()
            if let minutes = status.minutes,
               let interval = SlideshowInterval(rawValue: minutes) {
                currentSlideshowInterval = interval
            }
            if status.isShuffle {
                currentSlideshowOrder = .random
            } else if status.type == "slideshow" {
                currentSlideshowOrder = .inOrder
            }
            print("📺 Slideshow synced: interval=\(currentSlideshowInterval.displayName) order=\(currentSlideshowOrder.displayName)")
        } catch {
            print("📺 Slideshow read failed: \(error.localizedDescription)")
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
        do {
            try await artService.setSlideshowStatus(
                durationMinutes: currentSlideshowInterval.rawValue,
                shuffle: currentSlideshowOrder == .random
            )
            return true
        } catch {
            statusMessage = "Failed to set slideshow: \(error.localizedDescription)"
            return false
        }
    }
}
