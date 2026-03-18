import Foundation

// MARK: - SamsungArtError
// Typed errors for the entire Samsung art protocol layer.
enum SamsungArtError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case unauthorized
    case timeout(String)
    case tvError(request: String, errorCode: String)
    case encodingFailed(String)
    case decodingFailed(String)
    case uploadFailed(String)
    case tcpFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:                  return "Not connected to TV"
        case .connectionFailed(let msg):     return "Connection failed: \(msg)"
        case .unauthorized:                  return "TV rejected connection (unauthorized)"
        case .timeout(let msg):              return "Timeout: \(msg)"
        case .tvError(let req, let code):    return "TV error on \(req): code \(code)"
        case .encodingFailed(let msg):       return "Encoding error: \(msg)"
        case .decodingFailed(let msg):       return "Decoding error: \(msg)"
        case .uploadFailed(let msg):         return "Upload failed: \(msg)"
        case .tcpFailed(let msg):            return "TCP error: \(msg)"
        case .cancelled:                     return "Operation cancelled"
        }
    }
}

// MARK: - SamsungArtParser
//
// Owns all response parsing. Matches NickWaterton/samsung-tv-ws-api behavior.
//
// Python response flow:
//   1. WebSocket receives a JSON string
//   2. Outer JSON has "event" field (e.g. "d2d_service_message")
//   3. For d2d_service_message, "data" is a JSON STRING (double-encoded)
//   4. Inner JSON has "event" (sub-event), "request_id" or "id", and command-specific fields
//   5. Some inner fields (content_list, conn_info, data, etc.) are ALSO JSON strings
//
enum SamsungArtParser {

    // MARK: - Outer Message Parsing
    //
    // Python: helper.process_api_response(data) → json.loads(response)
    //
    struct OuterMessage: @unchecked Sendable {
        let event: String
        nonisolated(unsafe) let raw: [String: Any]

        // The full data dict (for ms.channel.connect which has data.token)
        nonisolated var data: [String: Any]? {
            raw["data"] as? [String: Any]
        }
    }

    nonisolated static func parseOuter(_ text: String) -> OuterMessage? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String
        else { return nil }
        return OuterMessage(event: event, raw: json)
    }

    // MARK: - Inner d2d_service_message Parsing
    //
    // Python: json.loads(response["data"])
    // The "data" field is a JSON string, not a dict.
    //
    struct InnerMessage: @unchecked Sendable {
        let event: String          // sub-event e.g. "get_content_list", "image_added", "error"
        let requestID: String?     // request_id or id — used for correlation
        nonisolated(unsafe) let raw: [String: Any]     // full inner dict for field access

        nonisolated var isError: Bool { event == "error" }

        nonisolated var errorCode: String? {
            raw["error_code"] as? String
        }

        // Python: json.loads(data['request_data'])['request']
        nonisolated var errorRequestName: String? {
            guard let reqDataStr = raw["request_data"] as? String,
                  let reqData = reqDataStr.data(using: .utf8),
                  let reqJSON = try? JSONSerialization.jsonObject(with: reqData) as? [String: Any]
            else { return nil }
            return reqJSON["request"] as? String
        }
    }

    nonisolated static func parseInner(from outer: OuterMessage) -> InnerMessage? {
        guard outer.event == "d2d_service_message",
              let dataStr = outer.raw["data"] as? String,
              let dataBytes = dataStr.data(using: .utf8),
              let innerJSON = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any]
        else { return nil }

        let event = innerJSON["event"] as? String ?? "*"
        // Python: data.get('request_id', data.get('id'))
        let requestID = innerJSON["request_id"] as? String ?? innerJSON["id"] as? String

        return InnerMessage(event: event, requestID: requestID, raw: innerJSON)
    }

    // Convenience: parse both layers from raw WebSocket text
    nonisolated static func parseD2DMessage(_ text: String) -> InnerMessage? {
        guard let outer = parseOuter(text) else { return nil }
        return parseInner(from: outer)
    }

    // MARK: - Field Extraction Helpers
    //
    // Many inner fields are themselves JSON strings. These helpers handle the decode.
    //

    // Python: json.loads(data["content_list"])
    nonisolated static func parseContentList(from inner: InnerMessage) -> [[String: Any]]? {
        guard let raw = inner.raw["content_list"] else { return nil }

        // Could be a JSON string (common) or already an array (defensive)
        if let str = raw as? String,
           let data = str.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return list
        }
        if let list = raw as? [[String: Any]] {
            return list
        }
        return nil
    }

    // Python: json.loads(data["conn_info"])
    nonisolated static func parseConnInfo(from inner: InnerMessage) -> ConnInfo? {
        guard let raw = inner.raw["conn_info"] else { return nil }

        let dict: [String: Any]?
        if let str = raw as? String,
           let data = str.data(using: .utf8) {
            dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let d = raw as? [String: Any] {
            dict = d
        } else {
            dict = nil
        }

        guard let dict,
              let ip = dict["ip"] as? String
        else { return nil }

        let port: Int
        if let p = dict["port"] as? Int { port = p }
        else if let s = dict["port"] as? String, let p = Int(s) { port = p }
        else { return nil }

        let secured: Bool
        if let b = dict["secured"] as? Bool { secured = b }
        else if let s = dict["secured"] as? String { secured = s.lowercased() == "true" }
        else { secured = false }

        let key = dict["key"] as? String

        return ConnInfo(ip: ip, port: port, secured: secured, key: key)
    }

    // MARK: - Token Extraction
    //
    // Python: _check_for_token(response) → response.get("data", {}).get("token")
    //
    nonisolated static func extractToken(from outer: OuterMessage) -> String? {
        outer.data?["token"] as? String
    }

    // MARK: - Known Outer Events
    //
    // Python: event.py constants
    //
    nonisolated static let d2dServiceMessage = "d2d_service_message"
    nonisolated static let channelConnect = "ms.channel.connect"
    nonisolated static let channelReady = "ms.channel.ready"
    nonisolated static let channelUnauthorized = "ms.channel.unauthorized"
    nonisolated static let channelTimeout = "ms.channel.timeOut"
    nonisolated static let errorEvent = "ms.error"

    // Python: IGNORE_EVENTS_AT_STARTUP
    nonisolated static let ignoreEventsAtStartup: Set<String> = [
        "ed.edenTV.update",
        "ms.voiceApp.hide"
    ]
}

// MARK: - ConnInfo
// Parsed connection info returned by the TV for thumbnail/upload TCP sockets.
struct ConnInfo {
    let ip: String
    let port: Int
    let secured: Bool
    let key: String?        // Present for uploads (secKey), absent for thumbnails
}

// MARK: - TVArtItem
//
// Typed model for items in the TV's art gallery.
// Fields mapped from the Python get_content_list response items.
//
// Python response item example:
//   {
//     "content_id": "MY-C0002_20240115123456",
//     "category_id": "MY-C0002",
//     "file_name": null,
//     "content_type": "photo",
//     "thumbnail_url": null,
//     "matte_id": "flexible_warm",
//     "portrait_matte_id": "flexible_warm",
//     "width": 3840,
//     "height": 2160,
//     "file_size": "2048000",
//     "image_date": "2024:01:15 12:34:56"
//   }
//
struct TVArtItem: Identifiable, Equatable, Sendable {
    let id: String              // content_id — the TV's unique ID for this item
    let categoryID: String      // e.g. "MY-C0002" (user photos), "SAM-..." (built-in)
    let contentType: String     // e.g. "photo"
    let matteID: String?        // e.g. "flexible_warm" or "none"
    let portraitMatteID: String?
    let width: Int?
    let height: Int?
    let fileSize: Int?
    let imageDate: String?

    var isUserPhoto: Bool { categoryID.hasPrefix("MY-") }
    var isBuiltIn: Bool { !isUserPhoto }

    // Parse from the raw dict returned by get_content_list
    static func from(_ dict: [String: Any]) -> TVArtItem? {
        guard let contentID = dict["content_id"] as? String else { return nil }

        let fileSize: Int?
        if let n = dict["file_size"] as? Int { fileSize = n }
        else if let s = dict["file_size"] as? String { fileSize = Int(s) }
        else { fileSize = nil }

        return TVArtItem(
            id: contentID,
            categoryID: dict["category_id"] as? String ?? "",
            contentType: dict["content_type"] as? String ?? "",
            matteID: dict["matte_id"] as? String,
            portraitMatteID: dict["portrait_matte_id"] as? String,
            width: dict["width"] as? Int,
            height: dict["height"] as? Int,
            fileSize: fileSize,
            imageDate: dict["image_date"] as? String
        )
    }
}

// MARK: - SlideshowStatus
// Typed model for slideshow settings.
struct SlideshowStatus: Sendable {
    let value: String      // "off" or minutes as string, e.g. "15"
    let type: String       // "slideshow" or "shuffleslideshow"
    let categoryID: String?

    var isShuffle: Bool { type == "shuffleslideshow" }
    var isOff: Bool { value == "off" || value == "0" }
    var minutes: Int? { Int(value) }
}
