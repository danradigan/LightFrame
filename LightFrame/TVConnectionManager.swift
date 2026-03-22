import Foundation
import SwiftUI
import Combine

// MARK: - MatteError
// Thrown when all matte fallback attempts fail.
enum MatteError: LocalizedError {
    case allFallbacksFailed(requested: String)

    var errorDescription: String? {
        switch self {
        case .allFallbacksFailed(let requested):
            return "Matte '\(requested)' and all fallbacks were rejected by the TV"
        }
    }
}

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
    // True while reading slideshow status from the TV — suppresses onChange write-back
    var isSyncingSlideshow: Bool = false

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
                // Defer to avoid publishing during view updates
                Task { @MainActor in
                    self.appState.updateReachability(reachable, for: tv)
                }
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

    // MARK: - Change Matte (with fallback)
    // Tries the requested matte, then falls back through safer options.
    // Returns the matte that the TV actually accepted.
    //
    // Fallback chain:
    //   1. Requested matte
    //   2. Shadowbox + same color (style was bad, color is fine)
    //   3. Shadowbox + polar (known-safe baseline)
    //
    // Throws only if ALL attempts fail (including "none", which has no fallback).
    @discardableResult
    func changeMatte(contentID: String, matte: Matte) async throws -> Matte {
        // Try the requested matte first
        do {
            try await sendChangeMatte(contentID: contentID, matte: matte)
            return matte
        } catch {
            artService.logHandler?("[Matte] Rejected \(matte.apiToken): \(error.localizedDescription)")
        }

        // "none" has no fallback — if the TV rejects it, something else is wrong
        guard matte.style != .none else {
            try await sendChangeMatte(contentID: contentID, matte: matte) // rethrow
            return matte // unreachable, but satisfies compiler
        }

        // Fallback 1: shadowbox + same color
        let fallback1 = Matte.fallbackPreservingColor(matte.color)
        if fallback1 != matte {
            do {
                try await sendChangeMatte(contentID: contentID, matte: fallback1)
                artService.logHandler?("[Matte] Fell back to \(fallback1.apiToken)")
                return fallback1
            } catch {
                artService.logHandler?("[Matte] Fallback 1 rejected \(fallback1.apiToken): \(error.localizedDescription)")
            }
        }

        // Fallback 2: shadowbox + polar (known-safe)
        let fallback2 = Matte.safeFallback
        if fallback2 != fallback1 {
            do {
                try await sendChangeMatte(contentID: contentID, matte: fallback2)
                artService.logHandler?("[Matte] Fell back to \(fallback2.apiToken)")
                return fallback2
            } catch {
                artService.logHandler?("[Matte] Fallback 2 rejected \(fallback2.apiToken): \(error.localizedDescription)")
            }
        }

        // Everything failed — throw the original error context
        throw MatteError.allFallbacksFailed(requested: matte.apiToken)
    }

    // Low-level matte send — no fallback, just the two-slot protocol dance.
    private func sendChangeMatte(contentID: String, matte: Matte) async throws {
        let matteToken = matte.apiToken
        if matte.style != .none {
            // Call 1: matte_id (landscape slot) — must succeed
            try await artService.changeMatteRaw(
                contentID: contentID,
                extraParams: ["matte_id": matteToken]
            )
            // Call 2: portrait_matte_id (portrait slot) — best effort
            do {
                try await artService.changeMatteRaw(
                    contentID: contentID,
                    extraParams: ["portrait_matte_id": matteToken]
                )
            } catch {
                artService.logHandler?("[Matte] portrait_matte_id failed (non-fatal): \(error.localizedDescription)")
            }
        } else {
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

    // MARK: - Upload Photo (with matte fallback)
    // If the TV rejects the matte (tvError), retries with fallback mattes.
    // Only tvError triggers fallback — timeouts, connection failures, etc. are
    // NOT matte rejections and must not re-upload (which would create duplicates).
    // This matches Nick's Python where upload() has no retry logic at all.
    // Returns (contentID, confirmedMatte) so callers can update their model.
    func uploadPhoto(imageData: Data, fileType: String, matte: Matte?) async throws -> (contentID: String, confirmedMatte: Matte?) {
        let originalMatte = matte

        // Attempt 1: upload with the requested matte
        do {
            let matteToken = originalMatte?.apiToken ?? "flexible_warm"
            let contentID = try await artService.uploadArt(
                imageData: imageData,
                fileType: fileType,
                matteID: matteToken,
                portraitMatteID: matteToken
            )
            return (contentID, originalMatte)
        } catch let error as SamsungArtError {
            // Only retry on tvError (TV explicitly rejected — e.g. matte not supported).
            // Timeouts, connection failures, etc. mean the image may already be
            // on the TV — retrying would create duplicates.
            guard case .tvError(let req, let code) = error else {
                artService.logHandler?("❌ Upload failed (non-tvError): \(error.localizedDescription ?? "unknown")")
                throw error
            }

            artService.logHandler?("❌ TV rejected upload: request=\(req) error_code=\(code)")

            // If no matte or matte is "none", no fallback to try
            guard let original = originalMatte, original.style != .none else {
                artService.logHandler?("❌ No matte fallback available (matte=\(originalMatte?.apiToken ?? "nil"))")
                throw error
            }

            // Try fallback mattes
            let fallbacks = [
                Matte.fallbackPreservingColor(original.color),
                Matte.safeFallback
            ]

            for fallback in fallbacks {
                do {
                    artService.logHandler?("[Upload] Retrying with \(fallback.apiToken) after \(original.apiToken) failed")
                    let contentID = try await artService.uploadArt(
                        imageData: imageData,
                        fileType: fileType,
                        matteID: fallback.apiToken,
                        portraitMatteID: fallback.apiToken
                    )
                    return (contentID, fallback)
                } catch let fallbackError as SamsungArtError {
                    // Only continue fallback chain on tvError
                    guard case .tvError = fallbackError else {
                        throw fallbackError
                    }
                    continue
                }
            }

            // All fallbacks failed — throw the original error
            throw error
        }
    }

    func getCurrentArtwork() async throws -> String? {
        let inner = try await artService.fetchCurrentArtwork()
        return inner.raw["content_id"] as? String
    }

    // MARK: - Slideshow

    func readSlideshowStatus() async {
        do {
            let status = try await artService.fetchSlideshowStatus()
            // Capture values before mutating to defer out of any view update cycle
            var newInterval = currentSlideshowInterval
            var newOrder = currentSlideshowOrder
            if let minutes = status.minutes,
               let interval = SlideshowInterval(rawValue: minutes) {
                newInterval = interval
            }
            if status.isShuffle {
                newOrder = .random
            } else if status.type == "slideshow" {
                newOrder = .inOrder
            }
            // Defer mutations to avoid publishing during view updates
            Task { @MainActor in
                isSyncingSlideshow = true
                currentSlideshowInterval = newInterval
                currentSlideshowOrder = newOrder
                isSyncingSlideshow = false
                print("📺 Slideshow synced: interval=\(currentSlideshowInterval.displayName) order=\(currentSlideshowOrder.displayName)")
            }
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
