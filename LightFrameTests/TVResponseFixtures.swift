import Foundation
@testable import LightFrame

// MARK: - TVResponseFixtures
//
// Builds realistic Samsung TV response JSON for testing.
// Constructs JSON programmatically to avoid escaping nightmares
// with the double-encoded envelope format.
//
enum TVResponseFixtures {

    // MARK: - Outer Message Builders

    /// Build a complete d2d_service_message outer envelope from inner fields.
    /// This is the format all art channel responses arrive in.
    static func d2dMessage(
        event subEvent: String,
        requestID: String? = nil,
        fields: [String: Any] = [:]
    ) -> String {
        var inner: [String: Any] = ["event": subEvent]
        if let rid = requestID {
            inner["request_id"] = rid
        }
        for (k, v) in fields {
            inner[k] = v
        }

        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let innerString = String(data: innerData, encoding: .utf8)!

        let outer: [String: Any] = [
            "event": "d2d_service_message",
            "data": innerString
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Build a ms.channel.connect response (with optional token).
    static func channelConnect(token: String? = nil) -> String {
        var data: [String: Any] = [:]
        if let token = token {
            data["token"] = token
        }

        let outer: [String: Any] = [
            "event": "ms.channel.connect",
            "data": data
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Build a ms.channel.ready response.
    static func channelReady() -> String {
        let outer: [String: Any] = ["event": "ms.channel.ready"]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Build a ms.channel.unauthorized response.
    static func channelUnauthorized() -> String {
        let outer: [String: Any] = ["event": "ms.channel.unauthorized"]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Build a ms.channel.timeOut response.
    static func channelTimeout() -> String {
        let outer: [String: Any] = ["event": "ms.channel.timeOut"]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    /// Build an ms.error response.
    static func errorMessage(_ message: String) -> String {
        let outer: [String: Any] = [
            "event": "ms.error",
            "data": ["message": message]
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        return String(data: outerData, encoding: .utf8)!
    }

    // MARK: - Inner Response Builders

    /// Build a get_content_list response with sample items.
    /// Note: content_list is a JSON STRING in the real protocol.
    static func contentListResponse(
        requestID: String = "test-uuid",
        items: [[String: Any]]? = nil
    ) -> String {
        let contentItems = items ?? [
            sampleArtItem(contentID: "MY-C0002_20240115123456", category: "MY-C0002"),
            sampleArtItem(contentID: "SAM-BUILTIN-001", category: "SAM-C0001")
        ]
        let listData = try! JSONSerialization.data(withJSONObject: contentItems)
        let listString = String(data: listData, encoding: .utf8)!

        return d2dMessage(
            event: "get_content_list",
            requestID: requestID,
            fields: ["content_list": listString]
        )
    }

    /// Build a single art item dict (as it appears inside content_list).
    static func sampleArtItem(
        contentID: String = "MY-C0002_20240115123456",
        category: String = "MY-C0002",
        contentType: String = "photo",
        matteID: String = "flexible_warm",
        portraitMatteID: String = "flexible_warm",
        width: Int = 3840,
        height: Int = 2160,
        fileSize: Any = "2048000",
        imageDate: String = "2024:01:15 12:34:56"
    ) -> [String: Any] {
        [
            "content_id": contentID,
            "category_id": category,
            "content_type": contentType,
            "matte_id": matteID,
            "portrait_matte_id": portraitMatteID,
            "width": width,
            "height": height,
            "file_size": fileSize,
            "image_date": imageDate
        ]
    }

    /// Build an error response from the TV.
    static func tvErrorResponse(
        requestID: String = "test-uuid",
        errorCode: String = "INVALID_CONTENT",
        originalRequest: String = "change_matte"
    ) -> String {
        let requestData = try! JSONSerialization.data(withJSONObject: ["request": originalRequest])
        let requestDataString = String(data: requestData, encoding: .utf8)!

        return d2dMessage(
            event: "error",
            requestID: requestID,
            fields: [
                "error_code": errorCode,
                "request_data": requestDataString
            ]
        )
    }

    /// Build a get_current_artwork response.
    static func currentArtworkResponse(
        requestID: String = "test-uuid",
        contentID: String = "MY-C0002_20240115123456",
        matteID: String = "flexible_warm"
    ) -> String {
        d2dMessage(
            event: "get_current_artwork",
            requestID: requestID,
            fields: [
                "content_id": contentID,
                "matte_id": matteID,
                "category_id": "MY-C0002"
            ]
        )
    }

    /// Build a ready_to_use response (upload Step 1 response).
    /// Note: conn_info is a JSON STRING in the real protocol.
    static func readyToUseResponse(
        requestID: String = "test-uuid",
        ip: String = "192.168.1.100",
        port: Int = 5000,
        secKey: String = "secKeyABC123",
        secured: Bool = false
    ) -> String {
        let connInfoDict: [String: Any] = [
            "ip": ip,
            "port": port,
            "key": secKey,
            "secured": secured
        ]
        let connData = try! JSONSerialization.data(withJSONObject: connInfoDict)
        let connString = String(data: connData, encoding: .utf8)!

        return d2dMessage(
            event: "ready_to_use",
            requestID: requestID,
            fields: ["conn_info": connString]
        )
    }

    /// Build a get_thumbnail_list response with conn_info.
    static func thumbnailListResponse(
        requestID: String = "test-uuid",
        ip: String = "192.168.1.100",
        port: Int = 5000,
        secured: Bool = false
    ) -> String {
        let connInfoDict: [String: Any] = [
            "ip": ip,
            "port": port,
            "secured": secured
        ]
        let connData = try! JSONSerialization.data(withJSONObject: connInfoDict)
        let connString = String(data: connData, encoding: .utf8)!

        return d2dMessage(
            event: "get_thumbnail_list",
            requestID: requestID,
            fields: ["conn_info": connString]
        )
    }

    /// Build an image_added response (upload completion).
    static func imageAddedResponse(contentID: String = "MY-C0002_20240301120000") -> String {
        d2dMessage(
            event: "image_added",
            fields: ["content_id": contentID]
        )
    }

    /// Build a slideshow_status response.
    static func slideshowStatusResponse(
        requestID: String = "test-uuid",
        value: String = "15",
        type: String = "shuffleslideshow",
        categoryID: String = "MY-C0002"
    ) -> String {
        d2dMessage(
            event: "get_slideshow_status",
            requestID: requestID,
            fields: [
                "value": value,
                "type": type,
                "category_id": categoryID
            ]
        )
    }

    /// Build an artmode_status response.
    static func artmodeStatusResponse(
        requestID: String = "test-uuid",
        value: String = "on"
    ) -> String {
        d2dMessage(
            event: "get_artmode_status",
            requestID: requestID,
            fields: ["value": value]
        )
    }

    /// Build a matte_list response.
    /// Note: matte_type_list and matte_color_list are JSON STRINGS.
    static func matteListResponse(requestID: String = "test-uuid") -> String {
        let styles: [[String: Any]] = [
            ["matte_type": "none"],
            ["matte_type": "shadowbox"],
            ["matte_type": "flexible"]
        ]
        let colors: [[String: Any]] = [
            ["color": "polar"],
            ["color": "warm"],
            ["color": "burgandy"]  // Samsung's misspelling
        ]

        let stylesData = try! JSONSerialization.data(withJSONObject: styles)
        let colorsData = try! JSONSerialization.data(withJSONObject: colors)

        return d2dMessage(
            event: "get_matte_list",
            requestID: requestID,
            fields: [
                "matte_type_list": String(data: stylesData, encoding: .utf8)!,
                "matte_color_list": String(data: colorsData, encoding: .utf8)!
            ]
        )
    }

    /// Build an api_version response.
    static func apiVersionResponse(
        requestID: String = "test-uuid",
        version: String = "4.3.5.0"
    ) -> String {
        d2dMessage(
            event: "api_version",
            requestID: requestID,
            fields: ["version": version]
        )
    }

    /// Build a device_info response.
    static func deviceInfoResponse(requestID: String = "test-uuid") -> String {
        d2dMessage(
            event: "get_device_info",
            requestID: requestID,
            fields: [
                "FrameTVSupport": "true",
                "GameModeSupport": "true",
                "TokenAuthSupport": "true",
                "device_name": "Samsung Frame TV",
                "model_name": "QN55LS03BAFXZA"
            ]
        )
    }

    // MARK: - Edge Case Builders

    /// Build a response where port is a String instead of Int (some firmware).
    static func connInfoWithStringPort(
        requestID: String = "test-uuid",
        port: String = "5000"
    ) -> String {
        let connInfoDict: [String: Any] = [
            "ip": "192.168.1.100",
            "port": port,
            "secured": "false",
            "key": "testKey"
        ]
        let connData = try! JSONSerialization.data(withJSONObject: connInfoDict)
        let connString = String(data: connData, encoding: .utf8)!

        return d2dMessage(
            event: "ready_to_use",
            requestID: requestID,
            fields: ["conn_info": connString]
        )
    }

    /// Build a response where content_list is an array, not a string (defensive).
    static func contentListAsArray(requestID: String = "test-uuid") -> String {
        let items: [[String: Any]] = [
            sampleArtItem(contentID: "test-1")
        ]
        return d2dMessage(
            event: "get_content_list",
            requestID: requestID,
            fields: ["content_list": items]
        )
    }

    /// Build a response where file_size is an Int, not a String.
    static func artItemWithIntFileSize() -> [String: Any] {
        sampleArtItem(contentID: "test-int-size", fileSize: 2048000)
    }

    /// Build a d2d message with no request_id (broadcast event).
    static func broadcastEvent(event: String, fields: [String: Any] = [:]) -> String {
        d2dMessage(event: event, requestID: nil, fields: fields)
    }
}
