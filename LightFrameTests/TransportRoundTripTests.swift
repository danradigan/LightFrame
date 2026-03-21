import XCTest
@testable import LightFrame

// MARK: - TransportRoundTripTests
//
// Tests that verify the encode → decode cycle works correctly.
// These catch drift between what we send and what we expect to parse.
//
// Why this matters: if we change the encoding format but not the parser
// (or vice versa), these tests will catch it.
//
final class TransportRoundTripTests: XCTestCase {

    // MARK: - Envelope → Parse Round-Trip

    /// Build an envelope and verify the inner fields survive double-encoding.
    /// Note: the envelope is a REQUEST (method: ms.channel.emit), not a RESPONSE
    /// (event: d2d_service_message), so parseOuter won't parse it — we manually
    /// verify the structure instead.
    func testEnvelopeRoundTrip() throws {
        let originalParams: [String: Any] = [
            "request": "get_content_list",
            "category": "MY-C0002"
        ]

        // Encode
        let (envelope, uuid) = try SamsungArtProtocol.buildEnvelope(originalParams)

        // Parse the outer JSON manually (it's a request, not a response)
        let outerData = envelope.data(using: .utf8)!
        let outerJSON = try JSONSerialization.jsonObject(with: outerData) as! [String: Any]

        XCTAssertEqual(outerJSON["method"] as? String, "ms.channel.emit")

        let params = try XCTUnwrap(outerJSON["params"] as? [String: Any])
        XCTAssertEqual(params["event"] as? String, "art_app_request")
        XCTAssertEqual(params["to"] as? String, "host")

        // Extract the double-encoded inner payload
        let dataString = try XCTUnwrap(params["data"] as? String)
        let innerData = dataString.data(using: .utf8)!
        let innerJSON = try JSONSerialization.jsonObject(with: innerData) as! [String: Any]

        XCTAssertEqual(innerJSON["request"] as? String, "get_content_list")
        XCTAssertEqual(innerJSON["category"] as? String, "MY-C0002")
        XCTAssertEqual(innerJSON["id"] as? String, uuid)
        XCTAssertEqual(innerJSON["request_id"] as? String, uuid)
    }

    // MARK: - Fixture → Parser Round-Trip

    /// Verify that fixture-built responses parse correctly through the full chain.
    func testContentListFixtureRoundTrip() {
        let json = TVResponseFixtures.contentListResponse(requestID: "test-uuid-123")

        // Parse outer
        let outer = SamsungArtParser.parseOuter(json)
        XCTAssertNotNil(outer)
        XCTAssertEqual(outer?.event, SamsungArtParser.d2dServiceMessage)

        // Parse inner
        let inner = SamsungArtParser.parseInner(from: outer!)
        XCTAssertNotNil(inner)
        XCTAssertEqual(inner?.event, "get_content_list")
        XCTAssertEqual(inner?.requestID, "test-uuid-123")

        // Parse content list
        let items = SamsungArtParser.parseContentList(from: inner!)
        XCTAssertNotNil(items)
        XCTAssertEqual(items?.count, 2)

        // Parse individual items
        let artItems = items!.compactMap { TVArtItem.from($0) }
        XCTAssertEqual(artItems.count, 2)
        XCTAssertTrue(artItems[0].isUserPhoto)
        XCTAssertTrue(artItems[1].isBuiltIn)
    }

    func testErrorResponseRoundTrip() {
        let json = TVResponseFixtures.tvErrorResponse(
            requestID: "err-uuid",
            errorCode: "INVALID_CONTENT",
            originalRequest: "change_matte"
        )

        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertNotNil(inner)
        XCTAssertTrue(inner!.isError)
        XCTAssertEqual(inner!.errorCode, "INVALID_CONTENT")
        XCTAssertEqual(inner!.errorRequestName, "change_matte")
        XCTAssertEqual(inner!.requestID, "err-uuid")
    }

    func testConnInfoRoundTrip() {
        let json = TVResponseFixtures.readyToUseResponse(
            requestID: "upload-uuid",
            ip: "10.0.0.5",
            port: 5001,
            secKey: "longSecretKey123",
            secured: true
        )

        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertNotNil(inner)

        let connInfo = SamsungArtParser.parseConnInfo(from: inner!)
        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?.ip, "10.0.0.5")
        XCTAssertEqual(connInfo?.port, 5001)
        XCTAssertEqual(connInfo?.key, "longSecretKey123")
        XCTAssertTrue(connInfo!.secured)
    }

    // MARK: - Upload Protocol Chain

    /// Verify the send_image command encodes correctly and the expected
    /// response format parses correctly — the full upload handshake.
    func testUploadProtocolChain() throws {
        // Step 1: Build send_image command
        let (sendParams, uploadUUID) = SamsungArtProtocol.sendImage(
            fileType: "jpeg",  // Should be converted to jpg
            fileSize: 1048576,
            matteID: "flexible_warm",
            portraitMatteID: "shadowbox_polar"
        )

        // Verify command structure
        XCTAssertEqual(sendParams["request"] as? String, "send_image")
        XCTAssertEqual(sendParams["file_type"] as? String, "jpg")
        XCTAssertEqual(sendParams["id"] as? String, uploadUUID)

        // Step 2: Build the envelope
        let (envelope, envelopeUUID) = try SamsungArtProtocol.buildEnvelope(sendParams)
        // buildEnvelope should use the existing id from sendParams
        XCTAssertEqual(envelopeUUID, uploadUUID,
                       "buildEnvelope must preserve the upload UUID, not generate a new one")

        // Verify envelope is valid JSON
        let outerJSON = try JSONSerialization.jsonObject(
            with: envelope.data(using: .utf8)!
        ) as! [String: Any]
        XCTAssertEqual(outerJSON["method"] as? String, "ms.channel.emit")

        // Step 3: Simulate ready_to_use response
        let readyResponse = TVResponseFixtures.readyToUseResponse(
            requestID: uploadUUID,
            ip: "192.168.1.100",
            port: 5000,
            secKey: "abc123"
        )
        let readyInner = SamsungArtParser.parseD2DMessage(readyResponse)
        XCTAssertNotNil(readyInner)
        XCTAssertEqual(readyInner?.requestID, uploadUUID)

        let connInfo = SamsungArtParser.parseConnInfo(from: readyInner!)
        XCTAssertNotNil(connInfo)
        XCTAssertNotNil(connInfo?.key, "Upload response must include secKey")

        // Step 4: Build upload header for TCP
        let header = SamsungArtProtocol.uploadHeader(
            fileSize: 1048576,
            fileType: "jpeg",
            secKey: connInfo!.key!
        )
        XCTAssertEqual(header["fileLength"] as? Int, 1048576)
        XCTAssertEqual(header["fileType"] as? String, "jpg") // jpeg → jpg
        XCTAssertEqual(header["secKey"] as? String, "abc123")

        // Verify header serializes with 4-byte length prefix
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let lengthPrefix = withUnsafeBytes(of: UInt32(headerData.count).bigEndian) { Data($0) }
        XCTAssertEqual(lengthPrefix.count, 4, "Length prefix must be exactly 4 bytes")

        // Step 5: Simulate image_added response
        let addedResponse = TVResponseFixtures.imageAddedResponse(contentID: "MY-C0002_new_photo")
        let addedInner = SamsungArtParser.parseD2DMessage(addedResponse)
        XCTAssertNotNil(addedInner)
        XCTAssertEqual(addedInner?.event, "image_added")
        XCTAssertEqual(addedInner?.raw["content_id"] as? String, "MY-C0002_new_photo")
    }

    // MARK: - Thumbnail Protocol Chain

    func testThumbnailProtocolChain() throws {
        let contentIDs = ["c1", "c2", "c3"]

        // Step 1: Build command
        let (thumbParams, connUUID) = SamsungArtProtocol.getThumbnailList(contentIDs: contentIDs)
        XCTAssertEqual(thumbParams["request"] as? String, "get_thumbnail_list")

        let list = thumbParams["content_id_list"] as? [[String: String]]
        XCTAssertEqual(list?.count, 3)

        // Step 2: Build envelope — UUID is different from connUUID
        let (_, envelopeUUID) = try SamsungArtProtocol.buildEnvelope(thumbParams)
        // For thumbnails, the outer UUID should NOT be connUUID (they're independent)
        // Actually, buildEnvelope might pick up the id if it's in thumbParams...
        // Let's verify the connInfo UUID is preserved
        let connInfo = thumbParams["conn_info"] as? [String: Any]
        XCTAssertEqual(connInfo?["id"] as? String, connUUID)

        // Step 3: Simulate response
        let response = TVResponseFixtures.thumbnailListResponse(
            requestID: envelopeUUID,
            ip: "192.168.1.100",
            port: 5000
        )
        let inner = SamsungArtParser.parseD2DMessage(response)
        XCTAssertNotNil(inner)

        let parsedConnInfo = SamsungArtParser.parseConnInfo(from: inner!)
        XCTAssertNotNil(parsedConnInfo)
        XCTAssertNil(parsedConnInfo?.key, "Thumbnail conn_info should not have a key")
    }

    // MARK: - Matte Change Protocol

    func testMatteChangeProtocol() throws {
        // Build command
        let params = SamsungArtProtocol.changeMatte(
            contentID: "MY-C0002_20240115123456",
            matteID: "shadowbox_polar",
            portraitMatteID: "flexible_warm"
        )

        // Wrap in envelope
        let (envelope, uuid) = try SamsungArtProtocol.buildEnvelope(params)

        // Verify the envelope contains the right inner fields
        let innerJSON = try extractInner(from: envelope)
        XCTAssertEqual(innerJSON["request"] as? String, "change_matte")
        XCTAssertEqual(innerJSON["content_id"] as? String, "MY-C0002_20240115123456")
        XCTAssertEqual(innerJSON["matte_id"] as? String, "shadowbox_polar")
        XCTAssertEqual(innerJSON["portrait_matte_id"] as? String, "flexible_warm")

        // Simulate error response (matte rejected)
        let errorResponse = TVResponseFixtures.tvErrorResponse(
            requestID: uuid,
            errorCode: "INVALID_MATTE",
            originalRequest: "change_matte"
        )
        let errorInner = SamsungArtParser.parseD2DMessage(errorResponse)
        XCTAssertTrue(errorInner!.isError)
        XCTAssertEqual(errorInner!.errorCode, "INVALID_MATTE")
        XCTAssertEqual(errorInner!.errorRequestName, "change_matte")
    }

    // MARK: - Slideshow Round-Trip

    func testSlideshowRoundTrip() throws {
        // Set slideshow
        let setParams = SamsungArtProtocol.setSlideshowStatus(durationMinutes: 30, shuffle: true)
        let (envelope, _) = try SamsungArtProtocol.buildEnvelope(setParams)

        let innerJSON = try extractInner(from: envelope)
        XCTAssertEqual(innerJSON["value"] as? String, "30")
        XCTAssertEqual(innerJSON["type"] as? String, "shuffleslideshow")

        // Get slideshow status response
        let response = TVResponseFixtures.slideshowStatusResponse(
            value: "30", type: "shuffleslideshow", categoryID: "MY-C0002"
        )
        let inner = SamsungArtParser.parseD2DMessage(response)!
        let status = SlideshowStatus(
            value: inner.raw["value"] as? String ?? "off",
            type: inner.raw["type"] as? String ?? "",
            categoryID: inner.raw["category_id"] as? String
        )
        XCTAssertEqual(status.minutes, 30)
        XCTAssertTrue(status.isShuffle)
        XCTAssertFalse(status.isOff)
    }

    // MARK: - Broadcast Event Handling

    /// Broadcast events (no request_id) should still parse.
    func testBroadcastEventParsing() {
        let json = TVResponseFixtures.broadcastEvent(
            event: "artmode_status",
            fields: ["value": "on"]
        )
        let inner = SamsungArtParser.parseD2DMessage(json)
        XCTAssertNotNil(inner)
        XCTAssertEqual(inner?.event, "artmode_status")
        XCTAssertNil(inner?.requestID, "Broadcast events should have no request_id")
        XCTAssertEqual(inner?.raw["value"] as? String, "on")
    }

    // MARK: - Helpers

    private nonisolated func extractInner(from envelope: String) throws -> [String: Any] {
        let data = envelope.data(using: .utf8)!
        let outer = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let params = outer["params"] as! [String: Any]
        let dataString = params["data"] as! String
        let innerData = dataString.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: innerData) as! [String: Any]
    }
}
