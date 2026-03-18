import Foundation
import Network

// MARK: - SamsungConnection
//
// Owns the WebSocket connection lifecycle for a Samsung Frame TV.
// Mirrors NickWaterton/samsung-tv-ws-api async_art.py + async_connection.py.
//
// Architecture (matching Python):
//   1. Open remote control channel → get ms.channel.connect → extract token
//   2. Open art channel → get ms.channel.connect → get ms.channel.ready
//   3. Start background recv loop on art channel
//   4. Commands are sent on the art channel; responses resolved via pending futures
//   5. If the art channel dies, re-open on next command (start_listening pattern)
//
// The remote control channel is opened once for token exchange, then closed.
// All art commands go through the persistent art channel.
//
// This class is NOT @MainActor — it does network I/O.
// Callers (SamsungArtService) bridge to MainActor as needed.
//
actor SamsungConnection {

    // MARK: - Configuration
    let host: String
    var port: Int
    var token: String?
    let name: String
    let sslDelegate = SSLBypassDelegate()

    // MARK: - Connection State
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    private(set) var state: State = .disconnected

    // MARK: - Art Channel
    private var artTask: URLSessionWebSocketTask?
    private var artSession: URLSession?
    private var recvLoopTask: Task<Void, Never>?

    // MARK: - Pending Requests
    // Python: self.pending_requests = {} — maps UUID or event name → Future
    // Swift equivalent: maps key → CheckedContinuation
    //
    // Keys can be:
    //   - A request UUID (for normal request/response correlation)
    //   - An event name like "image_added" (for wait_for_event pattern)
    //
    private var pendingRequests: [String: CheckedContinuation<SamsungArtParser.InnerMessage, Error>] = [:]

    // MARK: - Logging
    // Callback for protocol-level log messages.
    // Set by SamsungArtService to forward to the UI layer.
    var logHandler: ((String) -> Void)?

    // MARK: - Init

    init(host: String, port: Int = 8002, token: String? = nil, name: String = "LightFrame") {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
    }

    // MARK: - Log Helper

    private func log(_ message: String) {
        logHandler?(message)
        #if DEBUG
        print(message)
        #endif
    }

    // MARK: - Connect
    //
    // Python async_art.__init__ calls get_token() which opens a sync remote control
    // connection just to obtain the token. Then open() connects the art channel.
    //
    // We combine both into one connect() method:
    //   1. Open remote control WS → get token
    //   2. Open art channel WS → wait for ms.channel.ready
    //   3. Start recv loop
    //
    func connect() async throws {
        guard state == .disconnected || state == .error("") || {
            if case .error = state { return true }
            return false
        }() else {
            if state == .connected { return }
            throw SamsungArtError.connectionFailed("Already connecting")
        }

        state = .connecting
        log("🔌 Connecting to \(host):\(port)")

        // ── Step 1: Remote control channel for token ─────────────────────────
        // Python: async_art.get_token() → opens SamsungTVWS (sync) which does:
        //   connection.open() → recv ms.channel.connect → _check_for_token()
        //
        // We only do this if we don't already have a token.
        // If we have a token, skip straight to the art channel.
        if token == nil {
            do {
                try await obtainToken()
            } catch {
                log("⚠️ Token fetch failed: \(error.localizedDescription) — proceeding without token")
                // Don't fail entirely — some TVs work without a token
            }
        }

        // ── Step 2: Art channel ──────────────────────────────────────────────
        // Python: SamsungTVAsyncArt.open()
        //   → super().open() gets ms.channel.connect
        //   → then reads one more message expecting ms.channel.ready
        //
        try await openArtChannel()

        // ── Step 3: Start recv loop ──────────────────────────────────────────
        startRecvLoop()

        state = .connected
        log("✅ Connected to \(host)")
    }

    // MARK: - Obtain Token
    //
    // Opens a temporary remote control WebSocket, waits for ms.channel.connect,
    // extracts the token, then closes.
    //
    private func obtainToken() async throws {
        guard let url = SamsungArtProtocol.remoteControlURL(host: host, port: port, token: token) else {
            throw SamsungArtError.connectionFailed("Invalid remote control URL")
        }

        log("🔑 Opening remote control channel for token...")

        let session = makeSession(timeout: 15)
        let task = session.webSocketTask(with: url)
        task.resume()

        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // Python: skip IGNORE_EVENTS_AT_STARTUP, wait for ms.channel.connect
        let message = try await receiveHandshake(task: task, expect: SamsungArtParser.channelConnect, timeout: 15)

        if let newToken = SamsungArtParser.extractToken(from: message) {
            log("🔑 Got token: \(newToken)")
            self.token = newToken
        } else {
            log("🔑 No token in connect response (TV may not require pairing)")
        }
    }

    // MARK: - Open Art Channel
    //
    // Python: SamsungTVAsyncArt.open()
    //   1. super().open() → skip ignore events → expect ms.channel.connect → extract token
    //   2. Read one more message → expect ms.channel.ready
    //
    private func openArtChannel() async throws {
        // Close any existing art channel
        closeArtChannel()

        guard let url = SamsungArtProtocol.artChannelURL(host: host, port: port, token: token) else {
            throw SamsungArtError.connectionFailed("Invalid art channel URL")
        }

        log("🎨 Opening art channel...")

        let session = makeSession(timeout: 30)
        let task = session.webSocketTask(with: url)
        task.resume()

        // Phase 1: Wait for ms.channel.connect (base class open)
        let connectMsg = try await receiveHandshake(task: task, expect: SamsungArtParser.channelConnect, timeout: 15)

        // Extract token from art channel connect too (some firmware)
        if let newToken = SamsungArtParser.extractToken(from: connectMsg), self.token == nil {
            self.token = newToken
            log("🔑 Got token from art channel: \(newToken)")
        }

        // Phase 2: Wait for ms.channel.ready (art channel specific)
        // Python: data = await self.connection.recv() → expect MS_CHANNEL_READY_EVENT
        let readyMsg = try await receiveWithTimeout(task: task, timeout: 10)
        guard let outer = SamsungArtParser.parseOuter(readyMsg) else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw SamsungArtError.connectionFailed("Invalid response waiting for ms.channel.ready")
        }

        if outer.event != SamsungArtParser.channelReady {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw SamsungArtError.connectionFailed("Expected ms.channel.ready, got \(outer.event)")
        }

        log("🎨 Art channel ready")
        self.artTask = task
        self.artSession = session
    }

    // MARK: - Handshake Helper
    //
    // Reads messages, skipping IGNORE_EVENTS_AT_STARTUP, until we get the expected event.
    // Handles ms.channel.unauthorized and ms.channel.timeOut.
    // Python: async_connection.open() loop.
    //
    private func receiveHandshake(
        task: URLSessionWebSocketTask,
        expect expectedEvent: String,
        timeout: Double
    ) async throws -> SamsungArtParser.OuterMessage {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let text = try await receiveWithTimeout(task: task, timeout: deadline.timeIntervalSinceNow)
            guard let outer = SamsungArtParser.parseOuter(text) else { continue }

            // Skip startup noise
            if SamsungArtParser.ignoreEventsAtStartup.contains(outer.event) {
                log("⏭️ Skipping startup event: \(outer.event)")
                continue
            }

            // Check for failure events
            if outer.event == SamsungArtParser.channelUnauthorized {
                throw SamsungArtError.unauthorized
            }
            if outer.event == SamsungArtParser.channelTimeout {
                throw SamsungArtError.connectionFailed("TV timed out (token may be missing or incorrect)")
            }
            if outer.event == SamsungArtParser.errorEvent {
                let msg = outer.data?["message"] as? String ?? "Unknown error"
                throw SamsungArtError.connectionFailed(msg)
            }

            // Check for expected event
            if outer.event == expectedEvent {
                return outer
            }

            // Unexpected event — keep reading (firmware may send extra events)
            log("⏭️ Unexpected event during handshake: \(outer.event)")
        }

        throw SamsungArtError.timeout("Handshake timed out waiting for \(expectedEvent)")
    }

    // MARK: - Recv Loop
    //
    // Python: async_connection._do_start_listening() → loops reading messages
    // Dispatches d2d_service_message to process_event which resolves pending futures.
    //
    private func startRecvLoop() {
        recvLoopTask?.cancel()
        recvLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runRecvLoop()
        }
    }

    private func runRecvLoop() async {
        log("👂 Recv loop started")
        while !Task.isCancelled {
            guard let task = artTask else {
                log("👂 Recv loop: no art task, exiting")
                break
            }

            do {
                let msg = try await task.receive()
                guard case .string(let text) = msg else { continue }

                guard let outer = SamsungArtParser.parseOuter(text) else { continue }

                // Python: process_event(event, response)
                if outer.event == SamsungArtParser.d2dServiceMessage {
                    await processD2DMessage(outer: outer, rawText: text)
                } else {
                    log("📩 Non-d2d event: \(outer.event)")
                }

            } catch {
                if Task.isCancelled { break }
                log("👂 Recv loop error: \(error.localizedDescription)")
                // Connection died — fail all pending requests
                await failAllPending(error: SamsungArtError.connectionFailed("Art channel closed"))
                break
            }
        }
        log("👂 Recv loop ended")
    }

    // MARK: - Process d2d_service_message
    //
    // Python: async_art.process_event()
    //   1. Parse inner JSON from response["data"]
    //   2. Check request_id → resolve matching pending future
    //   3. Or check sub_event → resolve matching pending future (for wait_for_event)
    //
    private func processD2DMessage(outer: SamsungArtParser.OuterMessage, rawText: String) async {
        guard let inner = SamsungArtParser.parseInner(from: outer) else {
            log("📩 Could not parse inner d2d message")
            return
        }

        let subEvent = inner.event
        let requestID = inner.requestID
        log("📩 d2d sub_event=\(subEvent) request_id=\(requestID ?? "nil")")

        // Python: first check request_id match, then check sub_event match
        if let rid = requestID, let cont = pendingRequests.removeValue(forKey: rid) {
            cont.resume(returning: inner)
            return
        }

        if let cont = pendingRequests.removeValue(forKey: subEvent) {
            cont.resume(returning: inner)
            return
        }

        // No pending request matched — this is a broadcast (artmode_status, etc.)
        // Dump full payload for matte/image broadcasts to help debug matte issues
        if subEvent == "matte_changed" || subEvent == "image_selected" {
            let rawDump = inner.raw.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            log("📩 Broadcast \(subEvent) full payload: {\(rawDump)}")
        } else {
            log("📩 Unmatched d2d event: \(subEvent)")
        }
    }

    // MARK: - Fail All Pending
    private func failAllPending(error: Error) async {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Send Art Command
    //
    // Python: _send_art_request()
    //   1. Set id and request_id
    //   2. Register pending future (keyed by wait_for_event or request_id)
    //   3. start_listening() — ensure connection is alive
    //   4. send_command()
    //   5. wait_for_response() — await the future with timeout
    //
    // Returns the parsed inner message (already unwrapped from d2d_service_message).
    //
    func sendCommand(
        _ innerParams: [String: Any],
        waitForEvent: String? = nil,
        timeout: TimeInterval = 5
    ) async throws -> SamsungArtParser.InnerMessage {
        // Ensure connected (Python: start_listening() calls open() if not alive)
        try await ensureConnected()

        // Build envelope
        let (envelopeString, requestUUID) = try SamsungArtProtocol.buildEnvelope(innerParams)

        let requestType = innerParams["request"] as? String ?? "unknown"
        log("📤 Sending: \(requestType) [uuid: \(requestUUID.prefix(8))]")

        // Key is waitForEvent if provided, otherwise requestUUID
        let pendingKey = waitForEvent ?? requestUUID

        // Register pending request BEFORE sending (matches Python)
        let inner: SamsungArtParser.InnerMessage = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[pendingKey] = continuation

            // Send the command (fire-and-forget from continuation context)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.sendOnArtChannel(envelopeString)
                } catch {
                    if let cont = await self.removePending(key: pendingKey) {
                        cont.resume(throwing: error)
                    }
                }
            }

            // Start timeout task
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let cont = await self.removePending(key: pendingKey) {
                    cont.resume(throwing: SamsungArtError.timeout("\(requestType) timed out after \(Int(timeout))s"))
                }
            }
        }

        // Python: error check
        if inner.isError {
            let reqName = inner.errorRequestName ?? requestType
            let code = inner.errorCode ?? "unknown"
            throw SamsungArtError.tvError(request: reqName, errorCode: code)
        }

        log("✅ Response: \(requestType) (sub_event=\(inner.event))")
        return inner
    }

    // MARK: - Pending Request Management

    private func registerPending(key: String, continuation: CheckedContinuation<SamsungArtParser.InnerMessage, Error>) {
        pendingRequests[key] = continuation
    }

    @discardableResult
    private func removePending(key: String) -> CheckedContinuation<SamsungArtParser.InnerMessage, Error>? {
        pendingRequests.removeValue(forKey: key)
    }

    // MARK: - Wait for Event (no send)
    //
    // Registers a pending request keyed by event name without sending any command.
    // Used by upload to wait for image_added after the TCP transfer completes.
    // Python: wait_for_response("image_added", timeout=timeout)
    //
    func waitForEvent(_ eventName: String, timeout: TimeInterval) async throws -> SamsungArtParser.InnerMessage {
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[eventName] = continuation

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let cont = await self.removePending(key: eventName) {
                    cont.resume(throwing: SamsungArtError.timeout("waitForEvent(\(eventName)) timed out"))
                }
            }
        }
    }

    // MARK: - Log Handler Setter
    func setLogHandler(_ handler: ((String) -> Void)?) {
        self.logHandler = handler
    }

    // MARK: - Ensure Connected
    //
    // Python: start_listening() → if not is_alive(): open()
    //
    private func ensureConnected() async throws {
        if isArtChannelAlive { return }
        log("🔄 Art channel not alive — reconnecting...")
        try await openArtChannel()
        startRecvLoop()
        state = .connected
    }

    private var isArtChannelAlive: Bool {
        guard let task = artTask else { return false }
        return task.state == .running
    }

    // MARK: - Send on Art Channel

    private func sendOnArtChannel(_ text: String) async throws {
        guard let task = artTask, task.state == .running else {
            throw SamsungArtError.notConnected
        }
        try await task.send(.string(text))
    }

    // MARK: - Disconnect

    func disconnect() {
        log("🔌 Disconnecting from \(host)")
        recvLoopTask?.cancel()
        recvLoopTask = nil
        closeArtChannel()
        state = .disconnected

        // Fail any pending requests
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: SamsungArtError.notConnected)
        }
    }

    private func closeArtChannel() {
        artTask?.cancel(with: .goingAway, reason: nil)
        artTask = nil
        artSession?.invalidateAndCancel()
        artSession = nil
    }

    // MARK: - TCP Data Socket
    //
    // Used for thumbnail download and image upload.
    // Python: socket.socket() → connect() → send/recv
    // Swift: NWConnection with optional TLS.
    //
    // Returns a connected NWConnection. Caller is responsible for closing.
    //
    func openTCPSocket(connInfo: ConnInfo) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(connInfo.ip),
            port: NWEndpoint.Port(integerLiteral: UInt16(connInfo.port))
        )

        let nwParams: NWParameters
        if connInfo.secured {
            // Python: get_ssl_context() → ssl.CERT_NONE, check_hostname=False
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completionHandler in completionHandler(true) },
                .global(qos: .userInitiated)
            )
            nwParams = NWParameters(tls: tlsOptions)
        } else {
            nwParams = NWParameters.tcp
        }

        let connection = NWConnection(to: endpoint, using: nwParams)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var fired = false
            connection.stateUpdateHandler = { nwState in
                guard !fired else { return }
                switch nwState {
                case .ready:
                    fired = true
                    cont.resume()
                case .failed(let e):
                    fired = true
                    cont.resume(throwing: SamsungArtError.tcpFailed("Connect failed: \(e)"))
                case .cancelled:
                    fired = true
                    cont.resume(throwing: SamsungArtError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        log("📡 TCP connected to \(connInfo.ip):\(connInfo.port) secured=\(connInfo.secured)")
        return connection
    }

    // MARK: - TCP Send Helper
    func tcpSend(connection: NWConnection, data: Data, isComplete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: SamsungArtError.tcpFailed("Send: \(error)"))
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    // MARK: - TCP Receive Helper
    // Reads exactly `length` bytes, looping for partial reads.
    func tcpReceive(connection: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            try Task.checkCancellation()
            let remaining = length - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error = error {
                        cont.resume(throwing: SamsungArtError.tcpFailed("Receive: \(error)"))
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: SamsungArtError.tcpFailed("Connection closed during read"))
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - URLSession Factory

    private func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)
    }

    // MARK: - Receive Helpers

    // Receive a single WebSocket text message with a timeout.
    private func receiveWithTimeout(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> String {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let msg = try await task.receive()
                guard case .string(let text) = msg else {
                    throw SamsungArtError.decodingFailed("Expected text WebSocket message")
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SamsungArtError.timeout("WebSocket receive timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - State Access

    var isConnected: Bool { state == .connected }

    var currentToken: String? { token }
}
