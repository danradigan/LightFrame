import Foundation
import Combine
import Network

// MARK: - TV Error
enum TVError: LocalizedError {
    case notConnected
    case timeout
    case uploadFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:           return "Not connected to TV"
        case .timeout:                return "Request timed out"
        case .uploadFailed(let msg):  return "Upload failed: \(msg)"
        case .commandFailed(let msg): return "Command failed: \(msg)"
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    // Posted when the TV sends us a pairing token after first connection
    static let tvTokenReceived = Notification.Name("tvTokenReceived")
}

// MARK: - SSL Bypass Delegate
// Samsung Frame TVs use a self-signed certificate.
// This delegate tells URLSession to trust it anyway.
class SSLBypassDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - TVConnection
// Manages the WebSocket connection to a single Samsung Frame TV.
// The TV speaks first after connection — it sends ms.channel.connect
// containing our pairing token. We must wait for this before sending commands.
@MainActor
class TVConnection: ObservableObject {

    // MARK: - Connection State
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        var isConnected: Bool { self == .connected }

        var displayName: String {
            switch self {
            case .disconnected:    return "Disconnected"
            case .connecting:      return "Connecting..."
            case .connected:       return "Connected"
            case .error(let msg):  return "Error: \(msg)"
            }
        }
    }

    // MARK: - Published Properties
    @Published var state: ConnectionState = .disconnected

    // MARK: - Private Properties
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let sslDelegate = SSLBypassDelegate()
    private var keepaliveTask: Task<Void, Never>?
    private var listeningTask: Task<Void, Never>?
    private var tv: TV

    // A pending command waits here for the TV to respond
    private var pendingContinuation: CheckedContinuation<[String: Any]?, Error>?

    // MARK: - Init
    init(tv: TV) {
        self.tv = tv
    }

    // MARK: - Update TV Reference
    func update(tv: TV) {
        self.tv = tv
    }

    // MARK: - Connect
    /// Opens a WebSocket connection and waits for the TV's handshake message.
    func connect() async {
        guard state == .disconnected else { return }
        guard let url = tv.webSocketURL else {
            state = .error("Invalid TV IP address")
            return
        }

        state = .connecting
        print("🔌 Connecting to \(tv.name) at \(tv.ipAddress)")

        // Build URLSession with SSL bypass
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Samsung TVs always send ms.channel.connect first — wait for it
        do {
            let message = try await withTimeout(seconds: 15) {
                try await self.webSocketTask!.receive()
            }

            guard case .string(let text) = message,
                  let json = parseJSON(text),
                  let event = json["event"] as? String,
                  event == "ms.channel.connect"
            else {
                state = .error("Unexpected handshake from TV")
                disconnect()
                return
            }

            // Save the pairing token if the TV sent one
            if let data = json["data"] as? [String: Any],
               let token = data["token"] as? String {
                print("🔑 Received token: \(token)")
                NotificationCenter.default.post(
                    name: .tvTokenReceived,
                    object: nil,
                    userInfo: ["tvID": tv.id, "token": token]
                )
            }

            state = .connected
            print("✅ Connected to \(tv.name)")
            startKeepalive()
            startListening()

        } catch {
            state = .error(error.localizedDescription)
            disconnect()
        }
    }

    // MARK: - Disconnect
    func disconnect() {
        keepaliveTask?.cancel()
        listeningTask?.cancel()
        keepaliveTask = nil
        listeningTask = nil
        pendingContinuation?.resume(returning: nil)
        pendingContinuation = nil
        webSocketTask?.cancel()
        webSocketTask = nil
        urlSession = nil
        state = .disconnected
        print("🔌 Disconnected from \(tv.name)")
    }

    // MARK: - Send Art Command
    /// Sends a command to the TV's art app and waits for the response.
    func sendArtCommand(_ params: [String: Any]) async throws -> [String: Any]? {
        guard state == .connected else { throw TVError.notConnected }

        // Samsung requires the inner data to be a JSON string, not an object
        guard let dataString = toJSONString(params) else {
            throw TVError.commandFailed("Could not encode params")
        }

        let envelope: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to": "host",
                "data": dataString
            ]
        ]

        guard let jsonString = toJSONString(envelope) else {
            throw TVError.commandFailed("Could not encode envelope")
        }

        try await webSocketTask?.send(.string(jsonString))
        print("📤 Sent: \(params["request"] ?? "unknown")")

        // Wait for the TV to reply
        return try await withTimeout(seconds: 20) {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingContinuation = continuation
            }
        }
    }

    // MARK: - Art API

    /// List all art currently uploaded to the TV
    func getAvailableArt() async throws -> [[String: Any]] {
        let response = try await sendArtCommand([
            "request": "get_content_list",
            "category": "MY-C0002"
        ])
        guard let response,
              let dataStr = response["data"] as? String,
              let data = dataStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = parsed["content_list"] as? [[String: Any]]
        else { return [] }
        return list
    }

    /// Upload a photo and return the content ID the TV assigns it
    func uploadPhoto(imageData: Data, fileType: String, matte: Matte?) async throws -> String {
        let matteToken = matte?.apiToken ?? "flexible_warm"
        let response = try await sendArtCommand([
            "request": "send_image",
            "data": imageData.base64EncodedString(),
            "file_type": fileType.uppercased(),
            "matte": matteToken,
            "portrait_matte": matteToken
        ])
        guard let response,
              let dataStr = response["data"] as? String,
              let data = dataStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentID = parsed["content_id"] as? String
        else { throw TVError.uploadFailed("TV did not return a content ID") }
        print("✅ Uploaded photo, content ID: \(contentID)")
        return contentID
    }

    /// Delete one or more photos from the TV
    func deletePhotos(contentIDs: [String]) async throws {
        _ = try await sendArtCommand([
            "request": "delete_image_list",
            "content_id_list": contentIDs
        ])
        print("🗑️ Deleted \(contentIDs.count) photo(s)")
    }

    /// Set the currently displayed photo
    func selectPhoto(contentID: String) async throws {
        _ = try await sendArtCommand([
            "request": "select_image",
            "content_id": contentID,
            "show": true
        ])
    }

    /// Set slideshow playback order
    func setSlideshowOrder(_ order: SlideshowOrder) async throws {
        _ = try await sendArtCommand([
            "request": "set_slideshow_status",
            "value": order.rawValue
        ])
    }

    /// Set how long each photo shows before advancing
    func setSlideshowInterval(_ interval: SlideshowInterval) async throws {
        _ = try await sendArtCommand([
            "request": "set_slideshow_status",
            "duration": interval.rawValue
        ])
    }

    // MARK: - Keepalive
    // Ping every 15 seconds — Samsung closes idle connections after ~30s
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard state == .connected else { break }
                webSocketTask?.sendPing { error in
                    if let error = error {
                        print("🏓 Ping failed: \(error.localizedDescription)")
                        Task { @MainActor in self.state = .disconnected }
                    }
                }
            }
        }
    }

    // MARK: - Listen
    // Forwards incoming TV messages to any waiting command continuation
    private func startListening() {
        listeningTask?.cancel()
        listeningTask = Task {
            while !Task.isCancelled && state == .connected {
                do {
                    guard let task = webSocketTask else { break }
                    let message = try await task.receive()
                    if case .string(let text) = message {
                        if let json = parseJSON(text), let cont = pendingContinuation {
                            pendingContinuation = nil
                            cont.resume(returning: json)
                        }
                    }
                } catch {
                    if state == .connected {
                        state = .disconnected
                    }
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private func toJSONString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func withTimeout<T>(
        seconds: Double,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TVError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
