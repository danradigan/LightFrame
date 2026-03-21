import XCTest
@testable import LightFrame

final class SamsungArtParserTests: XCTestCase {

    // MARK: - Outer Message Parsing

    func testParseOuterValidD2D() {
        let json = TVResponseFixtures.d2dMessage(event: "test_event", requestID: "uuid-1")
        let outer = SamsungArtParser.parseOuter(json)
        XCTAssertNotNil(outer)
        XCTAssertEqual(outer?.event, "d2d_service_message")
    }

    func testParseOuterChannelConnect() {
        let json = TVResponseFixtures.channelConnect(token: "abc123")
        let outer = SamsungArtParser.parseOuter(json)
        XCTAssertNotNil(outer)
        XCTAssertEqual(outer?.event, "ms.channel.connect")
    }

    func testParseOuterChannelReady() {
        let json = TVResponseFixtures.channelReady()
        let outer = SamsungArtParser.parseOuter(json)
        XCTAssertNotNil(outer)
        XCTAssertEqual(outer?.event, "ms.channel.ready")
    }

    func testParseOuterInvalidJSON() {
        XCTAssertNil(SamsungArtParser.parseOuter("not json at all"))
    }

    func testParseOuterEmptyString() {
        XCTAssertNil(SamsungArtParser.parseOuter(""))
    }

    func testParseOuterMissingEvent() {
        let json = """
        {"type": "something", "data": "test"}
        """
        XCTAssertNil(SamsungArtParser.parseOuter(json))
    }

    func testParseOuterArray() {
        // JSON array instead of object — should be rejected
        XCTAssertNil(SamsungArtParser.parseOuter("[1,2,3]"))
    }

    // MARK: - Token Extraction

    func testExtractTokenPresent() {
        let json = TVResponseFixtures.channelConnect(token: "mytoken123")
        let outer = SamsungArtParser.parseOuter(json)!
        let token = SamsungArtParser.extractToken(from: outer)
        XCTAssertEqual(token, "mytoken123")
    }

    func testExtractTokenAbsent() {
        let json = TVResponseFixtures.channelConnect(token: nil)
        let outer = SamsungArtParser.parseOuter(json)!
        let token = SamsungArtParser.extractToken(from: outer)
        XCTAssertNil(token, "Should return nil when no token in connect response")
    }

    // MARK: - Inner Message Parsing (Double-Encoded)

    func testParseInnerFromD2D() {
        let json = TVResponseFixtures.d2dMessage(event: "get_content_list", requestID: "test-uuid")
        let outer = SamsungArtParser.parseOuter(json)!
        let inner = SamsungArtParser.parseInner(from: outer)

        XCTAssertNotNil(inner)
        XCTAssertEqual(inner?.event, "get_content_list")
        XCTAssertEqual(inner?.requestID, "test-uuid")
    }

    func testParseInnerRejectsNonD2D() {
        let json = TVResponseFixtures.channelConnect(token: "abc")
        let outer = SamsungArtParser.parseOuter(json)!
        let inner = SamsungArtParser.parseInner(from: outer)
        XCTAssertNil(inner, "parseInner should return nil for non-d2d events")
    }

    /// Python: data.get('request_id', data.get('id'))
    func testParseInnerFallbackToID() {
        // Build a d2d message with "id" but no "request_id"
        var inner: [String: Any] = ["event": "test_event", "id": "fallback-uuid"]
        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let innerString = String(data: innerData, encoding: .utf8)!
        let outer: [String: Any] = ["event": "d2d_service_message", "data": innerString]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        let outerString = String(data: outerData, encoding: .utf8)!

        let result = SamsungArtParser.parseD2DMessage(outerString)
        XCTAssertEqual(result?.requestID, "fallback-uuid")
    }

    /// request_id takes precedence over id (Python: data.get('request_id', data.get('id')))
    func testParseInnerRequestIDPrecedence() {
        var inner: [String: Any] = ["event": "test", "request_id": "req-uuid", "id": "old-uuid"]
        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let innerString = String(data: innerData, encoding: .utf8)!
        let outer: [String: Any] = ["event": "d2d_service_message", "data": innerString]
        let outerData = try! JSONSerialization.data(withJSONObject: outer)
        let outerString = String(data: outerData, encoding: .utf8)!

        let result = SamsungArtParser.parseD2DMessage(outerString)
        XCTAssertEqual(result?.requestID, "req-uuid")
    }

    /// Convenience method should handle the full parse chain.
    func testParseD2DMessageConvenience() {
        let json = TVResponseFixtures.d2dMessage(event: "image_added", fields: ["content_id": "c1"])
        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertNotNil(inner)
        XCTAssertEqual(inner?.event, "image_added")
        XCTAssertEqual(inner?.raw["content_id"] as? String, "c1")
    }

    func testParseD2DMessageInvalidOuter() {
        XCTAssertNil(SamsungArtParser.parseD2DMessage("garbage"))
    }

    // MARK: - Error Detection

    func testInnerMessageIsError() {
        let json = TVResponseFixtures.tvErrorResponse(
            requestID: "uuid-1",
            errorCode: "INVALID_CONTENT",
            originalRequest: "change_matte"
        )
        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertNotNil(inner)
        XCTAssertTrue(inner!.isError, "event='error' must be detected as an error")
        XCTAssertEqual(inner!.errorCode, "INVALID_CONTENT")
    }

    func testInnerMessageNotError() {
        let json = TVResponseFixtures.d2dMessage(event: "get_content_list", requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertFalse(inner!.isError)
    }

    func testErrorRequestName() {
        let json = TVResponseFixtures.tvErrorResponse(
            errorCode: "INVALID_PARAM",
            originalRequest: "send_image"
        )
        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertEqual(inner?.errorRequestName, "send_image",
                       "Should parse request name from request_data JSON string")
    }

    // MARK: - Content List Parsing

    /// content_list is typically a JSON STRING (triple-encoded).
    func testParseContentListFromString() {
        let json = TVResponseFixtures.contentListResponse(requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let items = SamsungArtParser.parseContentList(from: inner)

        XCTAssertNotNil(items)
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0]["content_id"] as? String, "MY-C0002_20240115123456")
        XCTAssertEqual(items?[1]["content_id"] as? String, "SAM-BUILTIN-001")
    }

    /// Some firmware may return content_list as an actual array (defensive handling).
    func testParseContentListFromArray() {
        let json = TVResponseFixtures.contentListAsArray(requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let items = SamsungArtParser.parseContentList(from: inner)

        XCTAssertNotNil(items, "Should handle content_list as a direct array")
        XCTAssertEqual(items?.count, 1)
    }

    func testParseContentListMissing() {
        let json = TVResponseFixtures.d2dMessage(event: "get_content_list", requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let items = SamsungArtParser.parseContentList(from: inner)
        XCTAssertNil(items)
    }

    // MARK: - ConnInfo Parsing

    func testParseConnInfoFromString() {
        let json = TVResponseFixtures.readyToUseResponse(
            requestID: "uuid-1",
            ip: "192.168.1.50",
            port: 5001,
            secKey: "mySecKey",
            secured: true
        )
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?.ip, "192.168.1.50")
        XCTAssertEqual(connInfo?.port, 5001)
        XCTAssertEqual(connInfo?.key, "mySecKey")
        XCTAssertEqual(connInfo?.secured, true)
    }

    /// Some firmware returns port as a string. Parser must handle both.
    func testParseConnInfoStringPort() {
        let json = TVResponseFixtures.connInfoWithStringPort(requestID: "uuid-1", port: "5000")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?.port, 5000, "Must parse port from string")
    }

    /// Some firmware returns secured as a string "true"/"false".
    func testParseConnInfoStringSecured() {
        let json = TVResponseFixtures.connInfoWithStringPort(requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?.secured, false, "Must parse 'false' string as false")
    }

    func testParseConnInfoMissingIP() {
        // conn_info without required "ip" field
        let connDict: [String: Any] = ["port": 5000]
        let connData = try! JSONSerialization.data(withJSONObject: connDict)
        let connString = String(data: connData, encoding: .utf8)!

        let json = TVResponseFixtures.d2dMessage(
            event: "ready_to_use",
            requestID: "uuid-1",
            fields: ["conn_info": connString]
        )
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNil(connInfo, "Must return nil when IP is missing")
    }

    func testParseConnInfoMissingPort() {
        let connDict: [String: Any] = ["ip": "192.168.1.1"]
        let connData = try! JSONSerialization.data(withJSONObject: connDict)
        let connString = String(data: connData, encoding: .utf8)!

        let json = TVResponseFixtures.d2dMessage(
            event: "ready_to_use",
            requestID: "uuid-1",
            fields: ["conn_info": connString]
        )
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNil(connInfo, "Must return nil when port is missing")
    }

    func testParseConnInfoNoKey() {
        let json = TVResponseFixtures.thumbnailListResponse(requestID: "uuid-1")
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNotNil(connInfo)
        XCTAssertNil(connInfo?.key, "Thumbnail responses don't include a key")
    }

    // MARK: - Known Event Constants

    func testKnownEventConstants() {
        XCTAssertEqual(SamsungArtParser.d2dServiceMessage, "d2d_service_message")
        XCTAssertEqual(SamsungArtParser.channelConnect, "ms.channel.connect")
        XCTAssertEqual(SamsungArtParser.channelReady, "ms.channel.ready")
        XCTAssertEqual(SamsungArtParser.channelUnauthorized, "ms.channel.unauthorized")
        XCTAssertEqual(SamsungArtParser.channelTimeout, "ms.channel.timeOut")
        XCTAssertEqual(SamsungArtParser.errorEvent, "ms.error")
    }

    func testIgnoreEventsAtStartup() {
        XCTAssertTrue(SamsungArtParser.ignoreEventsAtStartup.contains("ed.edenTV.update"))
        XCTAssertTrue(SamsungArtParser.ignoreEventsAtStartup.contains("ms.voiceApp.hide"))
        XCTAssertFalse(SamsungArtParser.ignoreEventsAtStartup.contains("ms.channel.connect"))
    }

    // MARK: - TVArtItem Parsing

    func testTVArtItemFromDict() {
        let dict = TVResponseFixtures.sampleArtItem(
            contentID: "MY-C0002_20240115123456",
            category: "MY-C0002",
            contentType: "photo",
            matteID: "flexible_warm",
            width: 3840,
            height: 2160,
            fileSize: "2048000",
            imageDate: "2024:01:15 12:34:56"
        )
        let item = TVArtItem.from(dict)

        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "MY-C0002_20240115123456")
        XCTAssertEqual(item?.categoryID, "MY-C0002")
        XCTAssertEqual(item?.contentType, "photo")
        XCTAssertEqual(item?.matteID, "flexible_warm")
        XCTAssertEqual(item?.width, 3840)
        XCTAssertEqual(item?.height, 2160)
        XCTAssertEqual(item?.fileSize, 2048000)
        XCTAssertEqual(item?.imageDate, "2024:01:15 12:34:56")
    }

    /// file_size comes as a string from the TV — must parse to Int.
    func testTVArtItemStringFileSize() {
        let dict = TVResponseFixtures.sampleArtItem(fileSize: "3000000")
        let item = TVArtItem.from(dict)
        XCTAssertEqual(item?.fileSize, 3000000)
    }

    /// Some firmware sends file_size as an Int.
    func testTVArtItemIntFileSize() {
        let dict = TVResponseFixtures.artItemWithIntFileSize()
        let item = TVArtItem.from(dict)
        XCTAssertEqual(item?.fileSize, 2048000)
    }

    func testTVArtItemMissingContentID() {
        let dict: [String: Any] = ["category_id": "MY-C0002"]
        let item = TVArtItem.from(dict)
        XCTAssertNil(item, "Must return nil without content_id")
    }

    func testTVArtItemIsUserPhoto() {
        let userItem = TVArtItem.from(TVResponseFixtures.sampleArtItem(category: "MY-C0002"))!
        XCTAssertTrue(userItem.isUserPhoto)
        XCTAssertFalse(userItem.isBuiltIn)
    }

    func testTVArtItemIsBuiltIn() {
        let builtIn = TVArtItem.from(TVResponseFixtures.sampleArtItem(category: "SAM-C0001"))!
        XCTAssertFalse(builtIn.isUserPhoto)
        XCTAssertTrue(builtIn.isBuiltIn)
    }

    // MARK: - SlideshowStatus Model

    func testSlideshowStatusOff() {
        let status = SlideshowStatus(value: "off", type: "slideshow", categoryID: nil)
        XCTAssertTrue(status.isOff)
        XCTAssertFalse(status.isShuffle)
        XCTAssertNil(status.minutes)
    }

    func testSlideshowStatusZero() {
        let status = SlideshowStatus(value: "0", type: "slideshow", categoryID: nil)
        XCTAssertTrue(status.isOff, "'0' should also be considered off")
    }

    func testSlideshowStatusActive() {
        let status = SlideshowStatus(value: "15", type: "shuffleslideshow", categoryID: "MY-C0002")
        XCTAssertFalse(status.isOff)
        XCTAssertTrue(status.isShuffle)
        XCTAssertEqual(status.minutes, 15)
    }

    // MARK: - SamsungArtError

    func testErrorDescriptions() {
        // Just verify all cases produce non-nil descriptions
        let errors: [SamsungArtError] = [
            .notConnected,
            .connectionFailed("test"),
            .unauthorized,
            .timeout("test"),
            .tvError(request: "test", errorCode: "code"),
            .encodingFailed("test"),
            .decodingFailed("test"),
            .uploadFailed("test"),
            .tcpFailed("test"),
            .cancelled
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
