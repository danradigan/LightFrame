import Foundation
import Combine
import Network

// MARK: - SamsungArtService
//
// High-level API for Samsung Frame TV art operations.
// No UI code should parse raw WebSocket JSON — all access goes through this layer.
//
// Mirrors NickWaterton/samsung-tv-ws-api SamsungTVAsyncArt public methods.
// Each method documents the corresponding Python method.
//
// This is @MainActor so Published properties drive SwiftUI.
// Network operations are dispatched to the SamsungConnection actor.
//
@MainActor
class SamsungArtService: ObservableObject {

    // MARK: - Published State
    @Published var connectionState: SamsungConnection.State = .disconnected
    @Published var lastError: String?

    // MARK: - Connection
    private var connection: (any ArtConnectionProtocol)?
    private let sslDelegate = SSLBypassDelegate()

    // MARK: - Configuration
    private(set) var host: String = ""
    private(set) var port: Int = 8002
    private(set) var token: String?

    // Log callback — set by the app to capture protocol logs for debug UI
    var logHandler: ((String) -> Void)?

    // MARK: - Init

    init() {}

    /// Test-only init: inject a mock connection conforming to ArtConnectionProtocol.
    /// Sets state to .connected so fetch/command methods work immediately.
    init(testConnection: any ArtConnectionProtocol) {
        self.connection = testConnection
        self.connectionState = .connected
    }

    // MARK: - Configure & Connect
    //
    // Call this when the user selects a TV. Creates a new SamsungConnection
    // and connects it.
    //
    func configure(host: String, port: Int = 8002, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
    }

    func connect() async throws {
        disconnect()

        let conn = SamsungConnection(host: host, port: port, token: token, name: "LightFrame")
        await conn.setLogHandler(logHandler)
        self.connection = conn

        connectionState = .connecting
        do {
            try await conn.connect()
            connectionState = .connected
            // Update token if connection obtained one
            if let newToken = await conn.currentToken, newToken != token {
                self.token = newToken
            }
        } catch {
            let msg = error.localizedDescription
            connectionState = .error(msg)
            lastError = msg
            throw error
        }
    }

    func disconnect() {
        if let conn = connection {
            Task { await conn.disconnect() }
        }
        connection = nil
        connectionState = .disconnected
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    // MARK: - Art List
    //
    // Python: available(category=None) → get_content_list
    // Returns typed TVArtItem array.
    //
    func fetchArtList(category: String? = nil) async throws -> [TVArtItem] {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getContentList(category: category)
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 10)

        guard let list = SamsungArtParser.parseContentList(from: inner) else {
            return []
        }

        var items = list.compactMap { TVArtItem.from($0) }

        // Python: filter by category if specified
        if let category = category {
            items = items.filter { $0.categoryID == category }
        }

        return items
    }

    // Convenience: Python available(category="MY-C0002")
    func fetchMyPhotos() async throws -> [TVArtItem] {
        try await fetchArtList(category: "MY-C0002")
    }

    // MARK: - Current Artwork
    //
    // Python: get_current() → get_current_artwork
    //
    func fetchCurrentArtwork() async throws -> SamsungArtParser.InnerMessage {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getCurrentArtwork()
        return try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
    }

    // MARK: - Select Image
    //
    // Python: select_image(content_id, category=None, show=True)
    //
    func selectImage(contentID: String, category: String? = nil, show: Bool = true) async throws {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.selectImage(contentID: contentID, category: category, show: show)
        _ = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
    }

    // MARK: - Delete
    //
    // Python: delete_list(content_ids)
    // Verifies the response content_id_list matches what was sent.
    //
    func deleteArt(contentIDs: [String]) async throws {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.deleteImageList(contentIDs: contentIDs)
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 10)

        // Python: return content_id_list == json.loads(data['content_id_list'])
        // We log a warning if the response doesn't match, but don't fail.
        if let responseListStr = inner.raw["content_id_list"] as? String,
           let responseData = responseListStr.data(using: .utf8),
           let responseList = try? JSONSerialization.jsonObject(with: responseData) as? [[String: Any]] {
            let returnedIDs = Set(responseList.compactMap { $0["content_id"] as? String })
            let sentIDs = Set(contentIDs)
            if returnedIDs != sentIDs {
                logHandler?("⚠️ Delete response mismatch: sent \(sentIDs.count), confirmed \(returnedIDs.count)")
            }
        }
    }

    // MARK: - Change Matte
    //
    // Samsung's change_matte has two independent slots: matte_id (landscape) and
    // portrait_matte_id (portrait). A single call with both fields only writes
    // portrait_matte_id. Use changeMatteRaw with one field per call to set each
    // slot independently. See TVConnectionManager.changeMatte for the two-call pattern.
    //
    func changeMatte(contentID: String, matteID: String, portraitMatteID: String? = nil) async throws {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.changeMatte(contentID: contentID, matteID: matteID, portraitMatteID: portraitMatteID)
        _ = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
    }

    // Send change_matte with specific fields only — used by TVConnectionManager to
    // set matte_id and portrait_matte_id independently in two separate calls.
    func changeMatteRaw(contentID: String, extraParams: [String: String]) async throws {
        let conn = try requireConnection()
        var params: [String: Any] = [
            "request": "change_matte",
            "content_id": contentID
        ]
        for (key, value) in extraParams {
            params[key] = value
        }
        _ = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
    }

    // MARK: - Slideshow
    //
    // Python: set_slideshow_status(duration, type, category)
    //
    func setSlideshowStatus(durationMinutes: Int, shuffle: Bool) async throws {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.setSlideshowStatus(durationMinutes: durationMinutes, shuffle: shuffle)
        _ = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
    }

    // Python: get_slideshow_status()
    func fetchSlideshowStatus() async throws -> SlideshowStatus {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getSlideshowStatus()
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)

        let value = inner.raw["value"] as? String ?? "off"
        let type = inner.raw["type"] as? String ?? ""
        let categoryID = inner.raw["category_id"] as? String

        return SlideshowStatus(value: value, type: type, categoryID: categoryID)
    }

    // MARK: - Art Mode Status
    //
    // Python: get_artmode() → get_artmode_status → data["value"]
    //
    func fetchArtmodeStatus() async throws -> Bool {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getArtmodeStatus()
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
        return (inner.raw["value"] as? String) == "on"
    }

    // MARK: - API Version
    //
    // Python: get_api_version() — tries new API first, falls back to old
    //
    func fetchAPIVersion() async throws -> String {
        let conn = try requireConnection()
        do {
            let inner = try await conn.sendCommand(SamsungArtProtocol.getAPIVersion(useNewAPI: true), waitForEvent: nil, timeout: 15)
            return inner.raw["version"] as? String ?? "unknown"
        } catch {
            let inner = try await conn.sendCommand(SamsungArtProtocol.getAPIVersion(useNewAPI: false), waitForEvent: nil, timeout: 15)
            return inner.raw["version"] as? String ?? "unknown"
        }
    }

    // MARK: - Device Info
    //
    // Python: get_device_info()
    //
    func fetchDeviceInfo() async throws -> [String: Any] {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getDeviceInfo()
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)
        return inner.raw
    }

    // MARK: - Matte List
    //
    // Python: get_matte_list()
    //
    func fetchMatteList() async throws -> (styles: [[String: Any]], colors: [[String: Any]]?) {
        let conn = try requireConnection()
        let params = SamsungArtProtocol.getMatteList()
        let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 15)

        let styles: [[String: Any]]
        if let str = inner.raw["matte_type_list"] as? String,
           let data = str.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            styles = list
        } else {
            styles = []
        }

        let colors: [[String: Any]]?
        if let str = inner.raw["matte_color_list"] as? String,
           let data = str.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            colors = list
        } else {
            colors = nil
        }

        return (styles, colors)
    }

    // MARK: - Thumbnails (Batch)
    //
    // Python: get_thumbnail_list(content_id_list)
    // Downloads multiple thumbnails over a single TCP socket.
    //
    // Returns: [contentID: imageData]
    //
    func fetchThumbnails(contentIDs: [String]) async throws -> [String: Data] {
        guard !contentIDs.isEmpty else { return [:] }
        let conn = try requireConnection()

        // Build and send the command
        let (thumbParams, _) = SamsungArtProtocol.getThumbnailList(contentIDs: contentIDs)
        let inner = try await conn.sendCommand(thumbParams, waitForEvent: nil, timeout: 30)

        // Parse conn_info
        guard let connInfo = SamsungArtParser.parseConnInfo(from: inner) else {
            throw SamsungArtError.decodingFailed("No conn_info in thumbnail response")
        }

        logHandler?("🖼️ TCP connect for \(contentIDs.count) thumbnails → \(connInfo.ip):\(connInfo.port)")

        // Open TCP socket and read thumbnails
        // Python: read loop with num/total/fileLength/fileID/fileType headers
        let tcpConnection = try await conn.openTCPSocket(connInfo: connInfo)
        defer { tcpConnection.cancel() }

        var result: [String: Data] = [:]
        var totalNumThumbnails = 1
        var currentThumb = -1

        while currentThumb + 1 < totalNumThumbnails {
            try Task.checkCancellation()

            // Python: header_len = int.from_bytes(art_socket.recv(4), "big")
            let headerLenBytes = try await conn.tcpReceive(connection: tcpConnection, length: 4)
            let headerLen = Int(headerLenBytes.withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            })

            // Python: header = json.loads(art_socket.recv(header_len))
            let headerBytes = try await conn.tcpReceive(connection: tcpConnection, length: headerLen)
            guard let header = try? JSONSerialization.jsonObject(with: headerBytes) as? [String: Any] else {
                logHandler?("❌ Failed to parse thumbnail header")
                break
            }

            // Python: thumbnail_data_len = int(header["fileLength"])
            let thumbnailDataLen: Int
            if let n = header["fileLength"] as? Int { thumbnailDataLen = n }
            else if let s = header["fileLength"] as? String, let n = Int(s) { thumbnailDataLen = n }
            else { logHandler?("❌ No fileLength in thumbnail header"); break }

            // Python: current_thumb = int(header["num"])
            if let n = header["num"] as? Int { currentThumb = n }
            else if let s = header["num"] as? String, let n = Int(s) { currentThumb = n }
            else { break }

            // Python: total_num_thumbnails = int(header["total"])
            if let n = header["total"] as? Int { totalNumThumbnails = n }
            else if let s = header["total"] as? String, let n = Int(s) { totalNumThumbnails = n }
            else { break }

            // Python: filename = "{}.{}".format(header["fileID"], header["fileType"])
            let fileID = header["fileID"] as? String ?? "unknown"

            // Read thumbnail bytes
            let thumbnailData = try await conn.tcpReceive(connection: tcpConnection, length: thumbnailDataLen)
            result[fileID] = thumbnailData

            logHandler?("🖼️ Thumbnail \(currentThumb + 1)/\(totalNumThumbnails): \(fileID) (\(thumbnailData.count) bytes)")
        }

        logHandler?("🖼️ Downloaded \(result.count) thumbnails")
        return result
    }

    // MARK: - Upload
    //
    // Python: upload(file, matte, portrait_matte, file_type, date)
    //
    // Multi-step protocol:
    //   1. send_image → wait for ready_to_use (conn_info)
    //   2. TCP socket: send header + image bytes in 64KB chunks
    //   3. Wait for image_added → returns content_id
    //
    // Supports Task cancellation at every checkpoint.
    //
    func uploadArt(
        imageData: Data,
        fileType: String,
        matteID: String = "flexible_warm",
        portraitMatteID: String = "flexible_warm"
    ) async throws -> String {
        let conn = try requireConnection()

        // Build send_image params
        let (sendParams, uploadUUID) = SamsungArtProtocol.sendImage(
            fileType: fileType,
            fileSize: imageData.count,
            matteID: matteID,
            portraitMatteID: portraitMatteID
        )

        logHandler?("📤 Upload: send_image (\(imageData.count) bytes, type=\(fileType), uuid=\(uploadUUID.prefix(8)))")

        // Python: self.pending_requests[request_data["id"]] = asyncio.Future()
        //         await self.send_command(...)
        //         return await self.wait_for_response(request_data["id"], timeout)
        let readyResponse = try await conn.sendCommand(sendParams, waitForEvent: nil, timeout: 30)

        try Task.checkCancellation()

        // Parse conn_info from ready_to_use response
        guard let connInfo = SamsungArtParser.parseConnInfo(from: readyResponse),
              let secKey = connInfo.key
        else {
            throw SamsungArtError.uploadFailed("No conn_info/key in ready_to_use response")
        }

        logHandler?("📡 Upload TCP → \(connInfo.ip):\(connInfo.port) secured=\(connInfo.secured)")

        // Python: reader, writer = await asyncio.open_connection(ip, port, ssl=ssl_context)
        let tcpConnection = try await conn.openTCPSocket(connInfo: connInfo)

        // Python: writer.write(len(header).to_bytes(4, "big"))
        //         writer.write(header.encode("ascii"))
        let headerDict = SamsungArtProtocol.uploadHeader(
            fileSize: imageData.count,
            fileType: fileType,
            secKey: secKey
        )
        guard let headerData = try? JSONSerialization.data(withJSONObject: headerDict),
              let headerBytes = String(data: headerData, encoding: .utf8)?.data(using: .ascii)
        else {
            tcpConnection.cancel()
            throw SamsungArtError.encodingFailed("Could not encode upload header")
        }

        let lengthPrefix = withUnsafeBytes(of: UInt32(headerBytes.count).bigEndian) { Data($0) }
        try await conn.tcpSend(connection: tcpConnection, data: lengthPrefix + headerBytes, isComplete: false)

        logHandler?("📡 Upload header sent (\(headerBytes.count) bytes)")

        // Python: async for chunk in chunker(file): writer.write(chunk); await writer.drain()
        let chunkSize = 64 * 1024
        var offset = 0
        while offset < imageData.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, imageData.count)
            let chunk = imageData[offset..<end]
            let isLast = end == imageData.count
            try await conn.tcpSend(connection: tcpConnection, data: chunk, isComplete: isLast)
            offset = end
        }

        logHandler?("📡 Upload: all bytes sent (\(imageData.count) bytes) — waiting for image_added")

        // Python: writer.close()
        //         data = await self.wait_for_response("image_added", timeout=timeout)
        //
        // Nick closes the writer (graceful FIN) then waits for image_added.
        // NWConnection.cancel() is a hard RST, not a graceful close, so we
        // wait for the TV to confirm receipt FIRST, then tear down the socket.
        let addedResponse = try await conn.waitForEvent("image_added", timeout: 300)
        tcpConnection.cancel()

        // Python: if data and data.get("event", "*") == "error": raise ResponseError(...)
        if addedResponse.isError {
            let reqName = addedResponse.errorRequestName ?? "send_image"
            let code = addedResponse.errorCode ?? "unknown"
            throw SamsungArtError.tvError(request: reqName, errorCode: code)
        }

        // Python: return data["content_id"] if data else None
        guard let contentID = addedResponse.raw["content_id"] as? String else {
            throw SamsungArtError.uploadFailed("image_added response missing content_id")
        }

        logHandler?("✅ Upload complete — content ID: \(contentID)")
        return contentID
    }

    // MARK: - Wait for Event (no send)
    //
    // Used by upload to wait for image_added after the TCP transfer.
    // Registers a pending request keyed by event name without sending any command.
    //
    func waitForEvent(_ eventName: String, timeout: TimeInterval = 60) async throws -> SamsungArtParser.InnerMessage {
        let conn = try requireConnection()
        return try await conn.waitForEvent(eventName, timeout: timeout)
    }

    // MARK: - Test Harness Support
    //
    // These methods are designed to be called from a TV context menu test harness.
    // Each returns a structured result that can be displayed in the UI.
    //

    struct TestResult: Sendable {
        let name: String
        let success: Bool
        let duration: TimeInterval
        let detail: String
    }

    /// Run a single named test. Returns a TestResult for display.
    func runTest(_ testName: String) async -> TestResult {
        let start = Date()
        do {
            let detail: String
            switch testName {
            case "connect":
                // Verify existing connection or reconnect if dropped.
                // Do NOT call connect() unconditionally — that tears down
                // the live connection and all pending state.
                if isConnected {
                    detail = "Already connected to \(host):\(port), token=\(token?.prefix(8) ?? "none")"
                } else {
                    try await connect()
                    detail = "Reconnected to \(host):\(port), token=\(token?.prefix(8) ?? "none")"
                }

            case "api_version":
                let version = try await fetchAPIVersion()
                detail = "API version: \(version)"

            case "device_info":
                let info = try await fetchDeviceInfo()
                detail = "Device info keys: \(info.keys.sorted().joined(separator: ", "))"

            case "art_list":
                let items = try await fetchArtList()
                let userCount = items.filter { $0.isUserPhoto }.count
                let builtInCount = items.filter { $0.isBuiltIn }.count
                detail = "\(items.count) items (\(userCount) user, \(builtInCount) built-in)"

            case "my_photos":
                let items = try await fetchMyPhotos()
                detail = "\(items.count) user photos"

            case "current_artwork":
                let inner = try await fetchCurrentArtwork()
                let contentID = inner.raw["content_id"] as? String ?? "unknown"
                detail = "Current: \(contentID)"

            case "slideshow_status":
                let status = try await fetchSlideshowStatus()
                detail = "Slideshow: value=\(status.value), type=\(status.type)"

            case "artmode_status":
                let isOn = try await fetchArtmodeStatus()
                detail = "Art mode: \(isOn ? "ON" : "OFF")"

            case "matte_list":
                let (styles, colors) = try await fetchMatteList()
                detail = "\(styles.count) styles, \(colors?.count ?? 0) colors"

            case "thumbnail_one":
                let items = try await fetchMyPhotos()
                guard let first = items.first else {
                    return TestResult(name: testName, success: false, duration: Date().timeIntervalSince(start), detail: "No photos to thumbnail")
                }
                let thumbs = try await fetchThumbnails(contentIDs: [first.id])
                let size = thumbs.values.first?.count ?? 0
                detail = "Thumbnail for \(first.id): \(size) bytes"

            default:
                detail = "Unknown test: \(testName)"
                return TestResult(name: testName, success: false, duration: Date().timeIntervalSince(start), detail: detail)
            }

            return TestResult(name: testName, success: true, duration: Date().timeIntervalSince(start), detail: detail)
        } catch {
            return TestResult(name: testName, success: false, duration: Date().timeIntervalSince(start), detail: error.localizedDescription)
        }
    }

    /// All available test names, in recommended execution order.
    static let availableTests = [
        "connect",
        "api_version",
        "device_info",
        "artmode_status",
        "art_list",
        "my_photos",
        "current_artwork",
        "slideshow_status",
        "matte_list",
        "thumbnail_one"
    ]

    // MARK: - TV Diagnostic Report
    //
    // Generates a structured JSON report capturing TV capabilities and behavior.
    // Designed to be shared across different model years for comparison.
    //
    // Usage: run from ProtocolTestSheet, copy the JSON, paste into a
    // conversation with Claude for cross-model analysis.
    //
    func generateDiagnosticReport() async -> [String: Any] {
        var report: [String: Any] = [
            "report_version": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "client": "LightFrame",
            "host": host,
            "port": port
        ]

        // API Version
        let apiStart = Date()
        do {
            let version = try await fetchAPIVersion()
            report["api_version"] = version
            report["api_version_time_ms"] = Int(Date().timeIntervalSince(apiStart) * 1000)
        } catch {
            report["api_version"] = "error: \(error.localizedDescription)"
        }

        // Device Info
        let devStart = Date()
        do {
            let info = try await fetchDeviceInfo()
            // Extract safe fields (no tokens or sensitive data)
            var safeInfo: [String: String] = [:]
            for key in ["FrameTVSupport", "GameModeSupport", "TokenAuthSupport",
                        "device_name", "model_name", "resolution", "countryCode"] {
                if let val = info[key] as? String { safeInfo[key] = val }
            }
            report["device_info"] = safeInfo
            report["device_info_all_keys"] = info.keys.sorted()
            report["device_info_time_ms"] = Int(Date().timeIntervalSince(devStart) * 1000)
        } catch {
            report["device_info"] = "error: \(error.localizedDescription)"
        }

        // Art Mode Status
        do {
            let artMode = try await fetchArtmodeStatus()
            report["artmode_status"] = artMode ? "on" : "off"
        } catch {
            report["artmode_status"] = "error: \(error.localizedDescription)"
        }

        // Content List — capture structure, not actual content
        let listStart = Date()
        do {
            let items = try await fetchArtList()
            let userCount = items.filter { $0.isUserPhoto }.count
            let builtInCount = items.filter { $0.isBuiltIn }.count
            let categories = Set(items.map { $0.categoryID }).sorted()

            report["content_list"] = [
                "total_items": items.count,
                "user_photos": userCount,
                "built_in": builtInCount,
                "categories": categories,
                "sample_fields": items.first.map { item -> [String: String] in
                    var fields: [String: String] = [:]
                    fields["has_content_id"] = "true"
                    fields["has_category_id"] = item.categoryID.isEmpty ? "false" : "true"
                    fields["has_matte_id"] = item.matteID != nil ? "true" : "false"
                    fields["has_portrait_matte_id"] = item.portraitMatteID != nil ? "true" : "false"
                    fields["has_width"] = item.width != nil ? "true" : "false"
                    fields["has_height"] = item.height != nil ? "true" : "false"
                    fields["has_file_size"] = item.fileSize != nil ? "true" : "false"
                    fields["has_image_date"] = item.imageDate != nil ? "true" : "false"
                    return fields
                } ?? [:]
            ]
            report["content_list_time_ms"] = Int(Date().timeIntervalSince(listStart) * 1000)
        } catch {
            report["content_list"] = "error: \(error.localizedDescription)"
        }

        // Matte List — capture what the TV supports
        do {
            let (styles, colors) = try await fetchMatteList()
            report["matte_support"] = [
                "styles": styles.compactMap { $0["matte_type"] as? String },
                "colors": colors?.compactMap { $0["color"] as? String } ?? [],
                "style_count": styles.count,
                "color_count": colors?.count ?? 0
            ]
        } catch {
            report["matte_support"] = "error: \(error.localizedDescription)"
        }

        // Slideshow Status
        do {
            let status = try await fetchSlideshowStatus()
            report["slideshow"] = [
                "value": status.value,
                "type": status.type,
                "category_id": status.categoryID ?? "nil"
            ]
        } catch {
            report["slideshow"] = "error: \(error.localizedDescription)"
        }

        // Current Artwork
        do {
            let current = try await fetchCurrentArtwork()
            var currentInfo: [String: String] = [:]
            for key in ["content_id", "matte_id", "portrait_matte_id", "category_id"] {
                if let val = current.raw[key] as? String { currentInfo[key] = val }
            }
            report["current_artwork"] = currentInfo
        } catch {
            report["current_artwork"] = "error: \(error.localizedDescription)"
        }

        return report
    }

    // MARK: - Private Helpers

    private func requireConnection() throws -> any ArtConnectionProtocol {
        guard let conn = connection else {
            throw SamsungArtError.notConnected
        }
        return conn
    }
}

// (waitForEvent and setLogHandler are defined directly on SamsungConnection)
