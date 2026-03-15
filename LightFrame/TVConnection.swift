import Foundation
import Combine
import Network
import Darwin

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
    static let tvTokenReceived = Notification.Name("tvTokenReceived")
}

// MARK: - SSL Bypass Delegate
// Samsung Frame TVs use a self-signed certificate issued by "SmartViewSDK".
// We bypass verification — safe on a local LAN connection.
// Python equivalent: sslopt={"cert_reqs": ssl.CERT_NONE}
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
//
// Based strictly on NickWaterton/samsung-tv-ws-api (the reference implementation).
// Source: https://github.com/NickWaterton/samsung-tv-ws-api
//
// CONNECTION ARCHITECTURE
// ──────────────────────
// Two WebSocket connections, both on port 8002 (wss://):
//
//   1. samsung.remote.control  → pairing only
//      - Connect, receive ms.channel.connect (contains token)
//      - Keep alive with pings, never send commands here
//
//   2. com.samsung.art-app     → all art commands
//      - Connect, wait for ms.channel.ready (not ms.channel.connect!)
//      - Send all art_app_request commands here
//      - Responses arrive as d2d_service_message events
//
// ENVELOPE FORMAT (from ArtChannelEmitCommand.art_app_request in art.py)
// ──────────────────────────────────────────────────────────────────────
//   {
//     "method": "ms.channel.emit",
//     "params": {
//       "event": "art_app_request",
//       "to": "host",
//       "data": "<JSON string of inner params>"   ← double-encoded
//     }
//   }
//
// NOTE: No clientIp or deviceName in params — Python library does not send these.
//
// RESPONSE MATCHING (from wait_for_response in art.py)
// ────────────────────────────────────────────────────
// Responses arrive as d2d_service_message with inner JSON containing:
//   - request_id (new API) or id (old API) — must match the UUID we sent
//   - event — the sub-event type (e.g. "set_slideshow_status", "ready_to_use")
//   - error_code — present only on errors
//
// UPLOAD PROTOCOL (from upload() in art.py / async_art.py)
// ─────────────────────────────────────────────────────────
//   1. Send send_image with conn_info{d2d_mode:socket, connection_id, id=same_uuid}
//      Both "id" and "request_id" in inner params must be the same UUID.
//      file_type must be "jpg" not "jpeg".
//   2. Await d2d_service_message with matching UUID (event will be "ready_to_use")
//      Response contains conn_info JSON with TV's {ip, port, key, secured}
//   3. Connect OUTBOUND TCP to conn_info["ip"] : conn_info["port"]
//   4. Send: 4-byte big-endian header length
//            + header JSON {num,total,fileLength,fileName,fileType,secKey,version}
//            + raw image bytes in 64KB chunks
//   5. Await d2d_service_message with event="image_added" → content_id
//
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

    // MARK: - Private
    private var pairingTask: URLSessionWebSocketTask?   // samsung.remote.control
    private var urlSession: URLSession?
    private let sslDelegate = SSLBypassDelegate()
    private var keepaliveTask: Task<Void, Never>?
    private var tv: TV
    private(set) var hasConnected = false  // True once we've successfully connected at least once

    // MARK: - Init
    init(tv: TV) {
        self.tv = tv
    }

    func update(tv: TV) {
        self.tv = tv
    }

    // MARK: - Connect
    func connect() async {
        guard state == .disconnected else { return }
        guard let pairingURL = tv.pairingURL else {
            state = .error("Invalid TV IP address")
            return
        }

        state = .connecting
        print("🔌 Connecting to \(tv.name) at \(tv.ipAddress)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)

        // ── Step 1: Pairing channel ──────────────────────────────────────────
        // Python: connection.py open() waits for MS_CHANNEL_CONNECT_EVENT
        // skipping IGNORE_EVENTS_AT_STARTUP (ed.edenTV.update, ms.voiceApp.hide)
        pairingTask = urlSession?.webSocketTask(with: pairingURL)
        pairingTask?.resume()

        do {
            let pairingMsg = try await withTimeout(seconds: 15) {
                try await self.receivePairingMessage()
            }

            guard case .string(let text) = pairingMsg,
                  let json  = parseJSON(text),
                  let event = json["event"] as? String,
                  event == "ms.channel.connect"
            else {
                state = .error("Unexpected pairing handshake")
                disconnect()
                return
            }

            // Python: _check_for_token checks data.token
            if let token = (json["data"] as? [String: Any])?["token"] as? String {
                print("🔑 Token: \(token)")
                NotificationCenter.default.post(
                    name: .tvTokenReceived,
                    object: nil,
                    userInfo: ["tvID": tv.id, "token": token]
                )
            }

            // ── Step 2: Art channel ──────────────────────────────────────────
            // We no longer keep a persistent art channel open.
            // Python reconnects for every command — we do the same in sendArtCommand.
            // Just verify the art channel is reachable once at connect time.
            guard let artURL = tv.artChannelURL else {
                state = .error("Could not build art channel URL")
                disconnect()
                return
            }

            let testTask = urlSession?.webSocketTask(with: artURL)
            testTask?.resume()
            let artMsg = try await withTimeout(seconds: 10) {
                try await testTask!.receive()
            }
            if case .string(let t) = artMsg {
                print("🎨 Art channel reachable: \(t.prefix(80))")
            }
            testTask?.cancel()

            state = .connected
            hasConnected = true
            print("✅ Connected to \(tv.name)")
            startKeepalive()

        } catch {
            print("❌ Connection failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            disconnect()
        }
    }

    // Receive on pairing channel, skipping startup noise events
    // Python: IGNORE_EVENTS_AT_STARTUP = (ED_EDENTV_UPDATE_EVENT, MS_VOICEAPP_HIDE_EVENT)
    private func receivePairingMessage() async throws -> URLSessionWebSocketTask.Message {
        let ignoreEvents = ["ed.edenTV.update", "ms.voiceApp.hide"]
        while true {
            let msg = try await pairingTask!.receive()
            if case .string(let text) = msg,
               let json  = parseJSON(text),
               let event = json["event"] as? String,
               ignoreEvents.contains(event) {
                print("⏭️ Skipping startup event: \(event)")
                continue
            }
            return msg
        }
    }

    // MARK: - Disconnect
    func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        pairingTask?.cancel(with: .goingAway, reason: nil)
        pairingTask = nil
        urlSession = nil
        hasConnected = false
        if state != .disconnected { state = .disconnected }
        print("🔌 Disconnected from \(tv.name)")
    }

    // MARK: - Send Art Command
    //
    // Python: _send_art_request() calls start_listening() before every command.
    // start_listening() calls open() if the connection is closed (is_alive() == false).
    // The TV closes the art channel after each response — Python reconnects transparently.
    //
    // We mirror this by opening a fresh art channel WebSocket for each command,
    // sending the command, reading the response, then letting the channel close.
    //
    func sendArtCommand(_ params: [String: Any]) async throws -> [String: Any]? {
        // Allow commands if we've ever successfully connected — art commands open
        // their own channels and don't need the pairing channel to be alive.
        guard hasConnected else { throw TVError.notConnected }
        guard let artURL = tv.artChannelURL else { throw TVError.notConnected }

        var innerParams = params
        let cmdUUID = UUID().uuidString
        innerParams["id"]         = cmdUUID
        innerParams["request_id"] = cmdUUID

        guard let dataString = toJSONString(innerParams) else {
            throw TVError.commandFailed("Could not encode params")
        }

        let envelope: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to":    "host",
                "data":  dataString
            ]
        ]

        guard let envelopeString = toJSONString(envelope) else {
            throw TVError.commandFailed("Could not encode envelope")
        }

        let requestType = params["request"] as? String ?? "unknown"
        print("📤 Sending: \(requestType) [uuid: \(cmdUUID.prefix(8))]")

        // Open a fresh art channel for this command
        // Python: start_listening() → open() → send_command() → wait_for_response()
        let session   = URLSession(configuration: .default, delegate: sslDelegate, delegateQueue: nil)
        let task      = session.webSocketTask(with: artURL)
        task.resume()

        // Wait for ms.channel.ready on the new connection
        let firstMsg = try await withTimeout(seconds: 10) { try await task.receive() }
        if case .string(let t) = firstMsg {
            if let j = parseJSON(t), let ev = j["event"] as? String, ev == "ms.channel.connect" {
                // Some firmware: connect first, then ready
                _ = try await withTimeout(seconds: 5) { try await task.receive() }
            }
        }

        // Send the command
        try await task.send(.string(envelopeString))

        // Read responses until we get one matching our UUID
        // Python: wait_for_response(request_uuid=cmdUUID)
        return try await withTimeout(seconds: 30) {
            while true {
                let msg = try await task.receive()
                guard case .string(let text) = msg else { continue }
                print("📩 CMD[\(cmdUUID.prefix(8))]: \(text.prefix(500))")

                guard let json     = self.parseJSON(text),
                      let event    = json["event"] as? String,
                      event        == "d2d_service_message",
                      let dataStr  = json["data"] as? String,
                      let dataBytes = dataStr.data(using: .utf8),
                      let dataJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
                else { continue }

                let subEvent  = dataJSON["event"]      as? String ?? ""
                let requestID = dataJSON["request_id"] as? String ?? dataJSON["id"] as? String ?? ""

                // Error check
                if subEvent == "error" {
                    let code = dataJSON["error_code"] as? String ?? "unknown"
                    throw TVError.commandFailed("TV error \(code)")
                }

                // Match by UUID
                if requestID == cmdUUID {
                    print("✅ Matched \(requestType) response (sub_event=\(subEvent))")
                    task.cancel()
                    return json
                }
            }
        }
    }

    // MARK: - Art API

    // Python: available(category=None) → get_content_list
    func getAvailableArt(category: String? = nil) async throws -> [[String: Any]] {
        let params: [String: Any] = category != nil
            ? ["request": "get_content_list", "category": category!]
            : ["request": "get_content_list", "category": NSNull()]

        let response = try await sendArtCommand(params)
        guard let response,
              let dataStr = response["data"] as? String,
              let data    = dataStr.data(using: .utf8),
              let parsed  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        // content_list can be a JSON string (double-encoded) or already an array
        if let listStr = parsed["content_list"] as? String,
           let listData = listStr.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] {
            // Filter by category if specified
            if let category = category {
                return list.filter { ($0["category_id"] as? String) == category }
            }
            return list
        }
        if let list = parsed["content_list"] as? [[String: Any]] {
            return list
        }
        return []
    }

    // Convenience: get only user-uploaded photos (MY-C0002)
    func getMyPhotos() async throws -> [[String: Any]] {
        return try await getAvailableArt(category: "MY-C0002")
    }

    // MARK: - Download Thumbnails (Batch)
    //
    // Line-by-line translation of get_thumbnail_list() from art.py lines 304-339.
    // Uses the same art channel + conn_info + TCP pattern as uploadViaSocket (which works).
    //
    func getThumbnails(contentIDs: [String]) async throws -> [String: Data] {
        guard hasConnected else { throw TVError.notConnected }
        guard let artURL = tv.artChannelURL else { throw TVError.notConnected }
        guard !contentIDs.isEmpty else { return [:] }

        // Python line 307: content_id_list=[{"content_id": id} for id in content_id_list]
        let contentIDList = contentIDs.map { ["content_id": $0] }

        // Python lines 308-317: data = self._send_art_request({...})
        let thumbUUID = UUID().uuidString
        let connectionID = Int(UInt32.random(in: 0..<UInt32.max))

        let innerParams: [String: Any] = [
            "request":         "get_thumbnail_list",
            "content_id_list": contentIDList,
            "id":              thumbUUID,
            "request_id":      thumbUUID,
            "conn_info": [
                "d2d_mode":      "socket",
                "connection_id": connectionID,
                "id":            thumbUUID
            ]
        ]

        guard let dataString = toJSONString(innerParams) else { return [:] }

        let envelope: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to":    "host",
                "data":  dataString
            ]
        ]

        guard let envelopeString = toJSONString(envelope) else { return [:] }

        print("🖼️ Requesting \(contentIDs.count) thumbnails [uuid: \(thumbUUID.prefix(8))]")

        // ── Open art channel (same as uploadViaSocket) ───────────────────────
        let session = URLSession(configuration: .default, delegate: sslDelegate, delegateQueue: nil)
        let artTask = session.webSocketTask(with: artURL)
        artTask.resume()

        let ignoreEvents = ["ed.edenTV.update", "ms.voiceApp.hide"]
        var handshakeComplete = false
        for _ in 0..<10 {
            let msg = try await withTimeout(seconds: 10) { try await artTask.receive() }
            if case .string(let text) = msg, let json = self.parseJSON(text), let ev = json["event"] as? String {
                if ignoreEvents.contains(ev) { continue }
                if ev == "ms.channel.connect" { continue }
                if ev == "ms.channel.ready" { handshakeComplete = true; break }
            }
        }
        guard handshakeComplete else {
            artTask.cancel()
            throw TVError.commandFailed("Art channel did not become ready")
        }

        // ── Send command ─────────────────────────────────────────────────────
        try await artTask.send(.string(envelopeString))

        // ── Wait for response (same parsing as uploadViaSocket) ──────────────
        // Python: data = self._send_art_request(...)  →  returns inner parsed dict
        // Python line 320: conn_info = json.loads(data["conn_info"])
        var dataJSON: [String: Any]? = nil

        let _: [String: Any] = try await withTimeout(seconds: 30) {
            while true {
                let msg = try await artTask.receive()
                guard case .string(let text) = msg else { continue }

                guard let json     = self.parseJSON(text),
                      let event    = json["event"] as? String,
                      event        == "d2d_service_message",
                      let dataStr  = json["data"] as? String,
                      let dataBytes = dataStr.data(using: .utf8),
                      let innerJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
                else { continue }

                let requestID = innerJSON["request_id"] as? String ?? innerJSON["id"] as? String ?? ""
                if requestID == thumbUUID {
                    dataJSON = innerJSON
                    return json
                }
            }
        }

        // Python line 320: conn_info = json.loads(data["conn_info"])
        guard let dataJSON,
              let connInfoStr   = dataJSON["conn_info"] as? String,
              let connInfoBytes = connInfoStr.data(using: .utf8),
              let connInfo      = try? JSONSerialization.jsonObject(with: connInfoBytes) as? [String: Any],
              let tvIP          = connInfo["ip"]   as? String,
              let tvPortRaw     = connInfo["port"]
        else {
            print("❌ get_thumbnail_list missing conn_info. dataJSON: \(String(describing: dataJSON))")
            artTask.cancel()
            throw TVError.commandFailed("No conn_info in thumbnail response")
        }

        let tvPort = tvPortRaw as? Int ?? Int(tvPortRaw as? String ?? "0") ?? 0

        // Python line 321-322:
        //   art_socket_raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        //   art_socket = get_ssl_context().wrap_socket(art_socket_raw) if conn_info.get('secured', False) else art_socket_raw
        let secured: Bool
        if let b = connInfo["secured"] as? Bool { secured = b }
        else if let s = connInfo["secured"] as? String { secured = s.lowercased() == "true" }
        else { secured = false }

        print("🖼️ TCP connect to \(tvIP):\(tvPort) secured=\(secured)")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(tvIP),
            port: NWEndpoint.Port(integerLiteral: UInt16(tvPort))
        )

        let nwParams: NWParameters
        if secured {
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

        // Python line 323: art_socket.connect((conn_info["ip"], int(conn_info["port"])))
        let tcpConnection = NWConnection(to: endpoint, using: nwParams)
        try await connectTCP(tcpConnection)

        // Python lines 324-338: read loop
        //   total_num_thumbnails = 1
        //   current_thumb = -1
        //   while current_thumb+1 < total_num_thumbnails:
        //       header_len = int.from_bytes(art_socket.recv(4), "big")
        //       header = json.loads(art_socket.recv(header_len))
        //       thumbnail_data_len = int(header["fileLength"])
        //       current_thumb = int(header["num"])
        //       total_num_thumbnails = int(header["total"])
        //       filename = "{}.{}".format(header["fileID"], header["fileType"])
        //       thumbnail_data = bytearray()
        //       while len(thumbnail_data) < thumbnail_data_len:
        //           packet = art_socket.recv(thumbnail_data_len - len(thumbnail_data))
        //           thumbnail_data.extend(packet)
        //       thumbnail_data_dict[filename] = thumbnail_data

        var result: [String: Data] = [:]
        var totalNumThumbnails = 1
        var currentThumb = -1

        while currentThumb + 1 < totalNumThumbnails {
            // header_len = int.from_bytes(art_socket.recv(4), "big")
            let headerLenBytes = try await tcpReceive(connection: tcpConnection, length: 4)
            let headerLen = Int(headerLenBytes.withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            })

            // header = json.loads(art_socket.recv(header_len))
            let headerBytes = try await tcpReceive(connection: tcpConnection, length: headerLen)
            guard let header = try? JSONSerialization.jsonObject(with: headerBytes) as? [String: Any] else {
                print("❌ Failed to parse thumbnail header. Raw: \(String(data: headerBytes, encoding: .utf8) ?? "?")")
                break
            }

            // thumbnail_data_len = int(header["fileLength"])
            let thumbnailDataLen: Int
            if let n = header["fileLength"] as? Int { thumbnailDataLen = n }
            else if let s = header["fileLength"] as? String, let n = Int(s) { thumbnailDataLen = n }
            else { print("❌ No fileLength in header: \(header)"); break }

            // current_thumb = int(header["num"])
            if let n = header["num"] as? Int { currentThumb = n }
            else if let s = header["num"] as? String, let n = Int(s) { currentThumb = n }
            else { print("❌ No num in header: \(header)"); break }

            // total_num_thumbnails = int(header["total"])
            if let n = header["total"] as? Int { totalNumThumbnails = n }
            else if let s = header["total"] as? String, let n = Int(s) { totalNumThumbnails = n }
            else { print("❌ No total in header: \(header)"); break }

            // filename = "{}.{}".format(header["fileID"], header["fileType"])
            let fileID = header["fileID"] as? String ?? "unknown"
            let fileType = header["fileType"] as? String ?? "jpg"
            let filename = "\(fileID).\(fileType)"

            // Read thumbnail bytes with loop (matching Python lines 334-337)
            let thumbnailData = try await tcpReceive(connection: tcpConnection, length: thumbnailDataLen)

            result[fileID] = thumbnailData
            print("🖼️ Thumbnail \(currentThumb + 1)/\(totalNumThumbnails): \(filename) (\(thumbnailData.count) bytes)")
        }

        // Python: writer.close() / implicit socket close
        tcpConnection.cancel()
        artTask.cancel()

        print("🖼️ Downloaded \(result.count) thumbnails total")
        return result
    }

    // Async TCP connect helper
    private func connectTCP(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var fired = false
            connection.stateUpdateHandler = { nwState in
                guard !fired else { return }
                switch nwState {
                case .ready:
                    fired = true; cont.resume()
                case .failed(let e):
                    fired = true; cont.resume(throwing: e)
                case .cancelled:
                    fired = true; cont.resume(throwing: TVError.timeout)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    // Async TCP receive helper — reads exactly `length` bytes, looping for partial reads.
    // NWConnection.receive can return fewer bytes than requested.
    private func tcpReceive(connection: NWConnection, length: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < length {
            let remaining = length - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: TVError.uploadFailed("TCP connection closed during read"))
                    }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }

    // Python: delete_list(content_ids) builds [{"content_id": id}, ...] not [id, ...]
    func deletePhotos(contentIDs: [String]) async throws {
        let contentIDList = contentIDs.map { ["content_id": $0] }
        _ = try await sendArtCommand([
            "request":         "delete_image_list",
            "content_id_list": contentIDList
        ])
        print("🗑️ Deleted \(contentIDs.count) photo(s)")
    }

    // Python: select_image(content_id, category=None, show=True)
    func selectPhoto(contentID: String) async throws {
        _ = try await sendArtCommand([
            "request":     "select_image",
            "category_id": NSNull(),
            "content_id":  contentID,
            "show":        true
        ])
    }

    // Python: set_slideshow_status(duration, type, category)
    // Duration and type MUST be sent together in one call.
    // Sending them separately causes each call to overwrite the other's setting.
    func setSlideshowStatus(order: SlideshowOrder, interval: SlideshowInterval) async throws {
        let minutes = interval.rawValue == 0 ? "off" : String(interval.rawValue)
        _ = try await sendArtCommand([
            "request":     "set_slideshow_status",
            "value":       minutes,
            "category_id": "MY-C0002",
            "type":        order == .random ? "shuffleslideshow" : "slideshow"
        ])
    }

    // Python: get_slideshow_status()
    func getSlideshowStatus() async throws -> [String: Any]? {
        return try await sendArtCommand(["request": "get_slideshow_status"])
    }

    // Parsed slideshow status — returns (interval minutes string, type string)
    // e.g. ("15", "shuffleslideshow") or ("off", "slideshow")
    func getParsedSlideshowStatus() async throws -> (value: String, type: String)? {
        guard let response = try await getSlideshowStatus(),
              let dataStr = response["data"] as? String,
              let dataBytes = dataStr.data(using: .utf8),
              let dataJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
        else { return nil }
        let value = dataJSON["value"] as? String ?? "off"
        let type  = dataJSON["type"]  as? String ?? ""
        return (value, type)
    }

    // Python: change_matte(content_id, matte_id, portrait_matte)
    // Updates the matte on a photo already on the TV without re-uploading.
    func changeMatte(contentID: String, matte: Matte) async throws {
        let matteToken = matte.apiToken
        var params: [String: Any] = [
            "request":    "change_matte",
            "content_id": contentID,
            "matte_id":   matteToken
        ]
        if matte.style != .none {
            params["portrait_matte_id"] = matteToken
        }
        _ = try await sendArtCommand(params)
        print("🎨 Matte changed to \(matteToken) for \(contentID)")
    }

    // Python: get_current_artwork()
    func getCurrentArtwork() async throws -> String? {
        let response = try await sendArtCommand(["request": "get_current_artwork"])
        guard let response,
              let dataStr = response["data"] as? String,
              let dataBytes = dataStr.data(using: .utf8),
              let dataJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
        else { return nil }
        return dataJSON["content_id"] as? String
    }

    // MARK: - Auto-Reconnect Wrapper
    // Wraps sendArtCommand with one retry after reconnecting.
    // Handles the case where the TV dropped the pairing channel during idle.
    func sendArtCommandWithRetry(_ params: [String: Any]) async throws -> [String: Any]? {
        do {
            return try await sendArtCommand(params)
        } catch TVError.notConnected {
            print("🔄 Not connected — attempting reconnect...")
            disconnect()
            await connect()
            guard state == .connected else { throw TVError.notConnected }
            return try await sendArtCommand(params)
        } catch TVError.timeout {
            print("🔄 Timeout — attempting reconnect...")
            disconnect()
            await connect()
            guard state == .connected else { throw TVError.timeout }
            return try await sendArtCommand(params)
        }
    }

    // MARK: - Upload
    func uploadPhoto(imageData: Data, fileType: String, matte: Matte?) async throws -> String {
        return try await uploadViaSocket(imageData: imageData, fileType: fileType, matte: matte)
    }

    // MARK: - Socket-based Upload
    //
    // Direct Swift translation of upload() in NickWaterton/samsungtvws/art.py
    //
    // Unlike sendArtCommand (single request/response), uploads are multi-step:
    //   1. Send send_image → receive ready_to_use (with conn_info)
    //   2. TCP socket transfer of image bytes
    //   3. Receive image_added (with content_id)
    // All three steps must happen on the SAME art channel WebSocket.
    // So we open a dedicated art channel here, keep it alive for the full flow,
    // then close it when done.
    //
    private func uploadViaSocket(imageData: Data, fileType: String, matte: Matte?) async throws -> String {
        guard hasConnected else { throw TVError.notConnected }
        guard let artURL = tv.artChannelURL else { throw TVError.notConnected }

        let matteToken = matte?.apiToken ?? "flexible_warm"

        // Python: if file_type == "jpeg": file_type = "jpg"
        let tvFileType = fileType.lowercased() == "jpeg" ? "jpg" : fileType.lowercased()

        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let imageDate = df.string(from: Date())

        // Python: art_uuid = str(uuid.uuid4()); id = request_id = conn_info.id = art_uuid
        let uploadUUID   = UUID().uuidString
        let connectionID = Int(UInt32.random(in: 0..<UInt32.max))  // randrange(4*1024*1024*1024)

        let innerParams: [String: Any] = [
            "request":           "send_image",
            "file_type":         tvFileType,
            "file_size":         imageData.count,
            "image_date":        imageDate,
            "matte_id":          matteToken,
            "portrait_matte_id": matteToken,
            "id":                uploadUUID,      // art_uuid
            "request_id":        uploadUUID,      // same as id
            "conn_info": [
                "d2d_mode":      "socket",
                "connection_id": connectionID,
                "id":            uploadUUID       // same as id
            ]
        ]

        guard let dataString = toJSONString(innerParams) else {
            throw TVError.commandFailed("Could not encode send_image params")
        }

        let envelope: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to":    "host",
                "data":  dataString
            ]
        ]

        guard let envelopeString = toJSONString(envelope) else {
            throw TVError.commandFailed("Could not encode envelope")
        }

        // ── Open a dedicated art channel for this upload ──────────────────────
        let session = URLSession(configuration: .default, delegate: sslDelegate, delegateQueue: nil)
        let uploadArtTask = session.webSocketTask(with: artURL)
        uploadArtTask.resume()

        // Wait for art channel handshake: ms.channel.connect then ms.channel.ready
        // Python: SamsungTVAsyncArt.open() → super().open() then waits for ms.channel.ready
        let ignoreEvents = ["ed.edenTV.update", "ms.voiceApp.hide"]
        var handshakeComplete = false

        for _ in 0..<10 {  // max 10 messages during handshake
            let msg = try await withTimeout(seconds: 10) { try await uploadArtTask.receive() }
            if case .string(let text) = msg, let json = self.parseJSON(text), let ev = json["event"] as? String {
                if ignoreEvents.contains(ev) { continue }
                if ev == "ms.channel.connect" { continue }  // first expected event
                if ev == "ms.channel.ready" { handshakeComplete = true; break }
            }
        }

        guard handshakeComplete else {
            uploadArtTask.cancel()
            throw TVError.uploadFailed("Art channel did not become ready")
        }

        print("📤 Sending: send_image (\(imageData.count) bytes, type=\(tvFileType), uuid=\(uploadUUID.prefix(8)))")

        // ── Send the send_image command ──────────────────────────────────────
        try await uploadArtTask.send(.string(envelopeString))

        // ── Wait for ready_to_use response matching our UUID ─────────────────
        // Python: wait_for_response(request_uuid=uploadUUID)
        var readyDataJSON: [String: Any]? = nil

        let _: [String: Any] = try await withTimeout(seconds: 30) {
            while true {
                let msg = try await uploadArtTask.receive()
                guard case .string(let text) = msg else { continue }
                print("📩 UPLOAD[\(uploadUUID.prefix(8))]: \(text.prefix(3000))")

                guard let json     = self.parseJSON(text),
                      let event    = json["event"] as? String,
                      event        == "d2d_service_message",
                      let dataStr  = json["data"] as? String,
                      let dataBytes = dataStr.data(using: .utf8),
                      let dataJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
                else { continue }

                let subEvent  = dataJSON["event"]      as? String ?? ""
                let requestID = dataJSON["request_id"] as? String ?? dataJSON["id"] as? String ?? ""

                if subEvent == "error" {
                    let code = dataJSON["error_code"] as? String ?? "unknown"
                    print("❌ Upload error code=\(code) full_data=\(dataJSON)")
                    throw TVError.uploadFailed("TV error \(code)")
                }

                if requestID == uploadUUID {
                    readyDataJSON = dataJSON
                    return json
                }
            }
        }

        // ── Parse conn_info from ready_to_use ────────────────────────────────
        // Python: conn_info = json.loads(data["conn_info"])
        guard let dataJSON    = readyDataJSON,
              let connInfoStr   = dataJSON["conn_info"] as? String,
              let connInfoBytes = connInfoStr.data(using: .utf8),
              let connInfo      = try? JSONSerialization.jsonObject(with: connInfoBytes) as? [String: Any],
              let tvIP          = connInfo["ip"]   as? String,
              let tvPortRaw     = connInfo["port"],
              let secKey        = connInfo["key"]  as? String
        else {
            print("❌ ready_to_use missing conn_info:")
            print("   readyDataJSON: \(String(describing: readyDataJSON))")
            uploadArtTask.cancel()
            throw TVError.uploadFailed("TV did not provide connection info")
        }

        let tvPort  = tvPortRaw as? Int ?? Int(tvPortRaw as? String ?? "0") ?? 0
        let secured = connInfo["secured"] as? Bool ?? false
        print("📡 Connecting outbound to TV at \(tvIP):\(tvPort) secured=\(secured)")

        // Python: header = json.dumps({num, total, fileLength, fileName, fileType, secKey, version})
        let headerDict: [String: Any] = [
            "num":        0,
            "total":      1,
            "fileLength": imageData.count,
            "fileName":   "dummy",
            "fileType":   tvFileType,
            "secKey":     secKey,
            "version":    "0.0.1"
        ]
        guard let headerJSON  = toJSONString(headerDict),
              let headerBytes = headerJSON.data(using: .ascii)
        else {
            uploadArtTask.cancel()
            throw TVError.uploadFailed("Could not encode upload header")
        }

        // ── TCP socket connection ────────────────────────────────────────────
        // Python: art_socket = get_ssl_context().wrap_socket(art_socket_raw) if secured
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(tvIP),
            port: NWEndpoint.Port(integerLiteral: UInt16(tvPort))
        )

        let nwParams: NWParameters
        if secured {
            // Samsung uses self-signed certs on the data socket too
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

        let tcpConnection = NWConnection(to: endpoint, using: nwParams)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var fired = false
            tcpConnection.stateUpdateHandler = { nwState in
                guard !fired else { return }
                switch nwState {
                case .ready:
                    fired = true; cont.resume()
                case .failed(let e):
                    fired = true; cont.resume(throwing: TVError.uploadFailed("TCP connect: \(e)"))
                case .cancelled:
                    fired = true; cont.resume(throwing: TVError.uploadFailed("TCP cancelled"))
                default: break
                }
            }
            tcpConnection.start(queue: .global(qos: .userInitiated))
        }
        print("📡 TCP connected to TV")

        // ── Send header ──────────────────────────────────────────────────────
        // Python: art_socket.send(len(header).to_bytes(4, "big")); art_socket.send(header.encode("ascii"))
        let lengthPrefix = withUnsafeBytes(of: UInt32(headerBytes.count).bigEndian) { Data($0) }
        try await tcpSend(connection: tcpConnection, data: lengthPrefix + headerBytes, isComplete: false)
        print("📡 Header sent (\(headerBytes.count) bytes)")

        // ── Send image data in 64KB chunks ───────────────────────────────────
        // Python: for chunk in chunker(file): art_socket.send(chunk)
        let chunkSize = 64 * 1024
        var offset    = 0
        while offset < imageData.count {
            let end    = min(offset + chunkSize, imageData.count)
            let chunk  = imageData[offset..<end]
            let isLast = end == imageData.count
            try await tcpSend(connection: tcpConnection, data: chunk, isComplete: isLast)
            offset = end
        }
        // Python async: writer.close() sends a clean TCP FIN
        // Python sync: doesn't close at all, just waits
        // NWConnection: cancel() sends RST which can cause errors on the TV side.
        // Instead, we leave the connection open — the TV will close it after processing.
        print("📡 All bytes sent (\(imageData.count) bytes) — waiting for image_added")

        // ── Wait for image_added on the same art channel ─────────────────────
        // Python: data = self.wait_for_response("image_added", timeout=timeout)
        let contentID: String = try await withTimeout(seconds: 60) {
            while true {
                let msg = try await uploadArtTask.receive()
                guard case .string(let text) = msg else { continue }
                print("📩 UPLOAD[\(uploadUUID.prefix(8))]: \(text.prefix(3000))")

                guard let json     = self.parseJSON(text),
                      let event    = json["event"] as? String,
                      event        == "d2d_service_message",
                      let dataStr  = json["data"] as? String,
                      let dataBytes = dataStr.data(using: .utf8),
                      let dataJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
                else { continue }

                let subEvent = dataJSON["event"] as? String ?? ""
                if subEvent == "image_added",
                   let cid = dataJSON["content_id"] as? String {
                    return cid
                }

                if subEvent == "error" {
                    let code = dataJSON["error_code"] as? String ?? "unknown"
                    print("❌ Upload error (image_added phase) code=\(code) full_data=\(dataJSON)")
                    throw TVError.uploadFailed("TV error during upload: \(code)")
                }
            }
        }

        uploadArtTask.cancel()
        tcpConnection.cancel()
        print("✅ Upload complete — content ID: \(contentID)")
        return contentID
    }

    // Async TCP send helper
    private func tcpSend(connection: NWConnection, data: Data, isComplete: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: TVError.uploadFailed("TCP send: \(error)"))
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    // MARK: - Keepalive
    // Pings the pairing channel periodically.
    // If the ping fails, we DON'T disconnect — the TV often drops the pairing channel
    // when art channel connections are active (uploads, scans, etc). Since all art commands
    // open their own channels, the connection is still functional without the pairing channel.
    // We only stop pinging; the connection stays in .connected state.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.state == .connected else { break }
                self.pairingTask?.sendPing { error in
                    if let error = error {
                        print("🏓 Ping failed (non-fatal): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func toJSONString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8)
        else { return nil }
        return str
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
