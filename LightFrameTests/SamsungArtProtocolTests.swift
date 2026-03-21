import XCTest
@testable import LightFrame

final class SamsungArtProtocolTests: XCTestCase {

    // MARK: - UUID Generation

    /// Samsung TVs expect lowercase UUIDs matching Python's str(uuid.uuid4()).
    /// If we send uppercase, the TV may fail to match responses.
    func testGenerateUUIDIsLowercase() {
        let uuid = SamsungArtProtocol.generateUUID()
        XCTAssertEqual(uuid, uuid.lowercased(), "UUID must be lowercase to match Python's str(uuid.uuid4())")
    }

    func testGenerateUUIDFormat() {
        let uuid = SamsungArtProtocol.generateUUID()
        XCTAssertTrue(uuid.contains("-"), "UUID must contain hyphens")
        XCTAssertEqual(uuid.count, 36, "UUID must be 36-char standard format (8-4-4-4-12)")

        // Verify pattern: 8-4-4-4-12
        let parts = uuid.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0].count, 8)
        XCTAssertEqual(parts[1].count, 4)
        XCTAssertEqual(parts[2].count, 4)
        XCTAssertEqual(parts[3].count, 4)
        XCTAssertEqual(parts[4].count, 12)
    }

    func testGenerateUUIDIsUnique() {
        let uuids = (0..<100).map { _ in SamsungArtProtocol.generateUUID() }
        XCTAssertEqual(Set(uuids).count, 100, "UUIDs must be unique")
    }

    // MARK: - Envelope Structure

    /// Verify the outer envelope matches Samsung's expected format exactly.
    func testBuildEnvelopeOuterStructure() throws {
        let inner: [String: Any] = ["request": "get_device_info"]
        let (envelope, _) = try SamsungArtProtocol.buildEnvelope(inner)

        let json = try parseJSON(envelope)
        XCTAssertEqual(json["method"] as? String, "ms.channel.emit")

        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["event"] as? String, "art_app_request")
        XCTAssertEqual(params["to"] as? String, "host")

        // Critical: data must be a STRING (double-encoded), not a nested dict
        XCTAssertTrue(params["data"] is String,
                      "Inner payload must be a JSON string, not a nested object — Samsung expects double-encoding")
    }

    /// Verify the inner payload can be decoded from the data string.
    func testBuildEnvelopeDoubleEncoding() throws {
        let inner: [String: Any] = ["request": "get_device_info"]
        let (envelope, uuid) = try SamsungArtProtocol.buildEnvelope(inner)

        let innerJSON = try extractInner(from: envelope)
        XCTAssertEqual(innerJSON["request"] as? String, "get_device_info")
        XCTAssertEqual(innerJSON["id"] as? String, uuid)
        XCTAssertEqual(innerJSON["request_id"] as? String, uuid)
    }

    /// id and request_id must be the SAME value — Samsung uses both (old API / new API).
    func testBuildEnvelopeUUIDInjection() throws {
        let inner: [String: Any] = ["request": "test"]
        let (envelope, uuid) = try SamsungArtProtocol.buildEnvelope(inner)

        XCTAssertEqual(uuid, uuid.lowercased(), "Envelope UUID must be lowercase")

        let innerJSON = try extractInner(from: envelope)
        XCTAssertEqual(innerJSON["id"] as? String, innerJSON["request_id"] as? String,
                       "id and request_id must match (Python: request_data['request_id'] = request_data['id'])")
        XCTAssertEqual(innerJSON["id"] as? String, uuid)
    }

    func testBuildEnvelopeCustomUUID() throws {
        let customUUID = "custom-uuid-1234"
        let inner: [String: Any] = ["request": "test"]
        let (_, uuid) = try SamsungArtProtocol.buildEnvelope(inner, uuid: customUUID)
        XCTAssertEqual(uuid, customUUID)
    }

    func testBuildEnvelopePreservesExistingID() throws {
        let existingID = "existing-id-5678"
        let inner: [String: Any] = ["request": "test", "id": existingID]
        let (envelope, uuid) = try SamsungArtProtocol.buildEnvelope(inner)

        XCTAssertEqual(uuid, existingID)
        let innerJSON = try extractInner(from: envelope)
        XCTAssertEqual(innerJSON["request_id"] as? String, existingID,
                       "request_id must be set to existing id value")
    }

    /// Verify all inner fields survive the double-encoding round-trip.
    func testBuildEnvelopePreservesAllFields() throws {
        let inner: [String: Any] = [
            "request": "send_image",
            "file_size": 2048000,
            "matte_id": "flexible_warm",
            "file_type": "jpg"
        ]
        let (envelope, _) = try SamsungArtProtocol.buildEnvelope(inner)
        let decoded = try extractInner(from: envelope)

        XCTAssertEqual(decoded["request"] as? String, "send_image")
        XCTAssertEqual(decoded["file_size"] as? Int, 2048000)
        XCTAssertEqual(decoded["matte_id"] as? String, "flexible_warm")
        XCTAssertEqual(decoded["file_type"] as? String, "jpg")
    }

    // MARK: - Command Builders

    func testGetContentListNoCategory() {
        let params = SamsungArtProtocol.getContentList()
        XCTAssertEqual(params["request"] as? String, "get_content_list")
        XCTAssertTrue(params["category"] is NSNull,
                      "category must be NSNull when nil (Python: category=None)")
    }

    func testGetContentListWithCategory() {
        let params = SamsungArtProtocol.getContentList(category: "MY-C0002")
        XCTAssertEqual(params["request"] as? String, "get_content_list")
        XCTAssertEqual(params["category"] as? String, "MY-C0002")
    }

    func testGetCurrentArtwork() {
        let params = SamsungArtProtocol.getCurrentArtwork()
        XCTAssertEqual(params["request"] as? String, "get_current_artwork")
        XCTAssertEqual(params.count, 1, "Should only have 'request' field")
    }

    func testGetArtmodeStatus() {
        let params = SamsungArtProtocol.getArtmodeStatus()
        XCTAssertEqual(params["request"] as? String, "get_artmode_status")
    }

    func testSetArtmodeStatusOn() {
        let params = SamsungArtProtocol.setArtmodeStatus(on: true)
        XCTAssertEqual(params["request"] as? String, "set_artmode_status")
        XCTAssertEqual(params["value"] as? String, "on")
    }

    func testSetArtmodeStatusOff() {
        let params = SamsungArtProtocol.setArtmodeStatus(on: false)
        XCTAssertEqual(params["value"] as? String, "off")
    }

    func testSelectImageCommand() {
        let params = SamsungArtProtocol.selectImage(contentID: "test-123", show: true)
        XCTAssertEqual(params["request"] as? String, "select_image")
        XCTAssertEqual(params["content_id"] as? String, "test-123")
        XCTAssertEqual(params["show"] as? Bool, true)
        XCTAssertTrue(params["category_id"] is NSNull)
    }

    func testSelectImageWithCategory() {
        let params = SamsungArtProtocol.selectImage(contentID: "c1", category: "MY-C0002", show: false)
        XCTAssertEqual(params["category_id"] as? String, "MY-C0002")
        XCTAssertEqual(params["show"] as? Bool, false)
    }

    /// delete_image_list must use [{content_id: id}, ...] NOT [id, ...]
    /// Getting this wrong means the TV silently ignores the delete.
    func testDeleteImageListFormat() {
        let ids = ["id1", "id2", "id3"]
        let params = SamsungArtProtocol.deleteImageList(contentIDs: ids)
        XCTAssertEqual(params["request"] as? String, "delete_image_list")

        let list = params["content_id_list"] as? [[String: String]]
        XCTAssertNotNil(list, "content_id_list must be an array of dicts")
        XCTAssertEqual(list?.count, 3)
        XCTAssertEqual(list?[0]["content_id"], "id1")
        XCTAssertEqual(list?[1]["content_id"], "id2")
        XCTAssertEqual(list?[2]["content_id"], "id3")
    }

    func testDeleteImageListEmpty() {
        let params = SamsungArtProtocol.deleteImageList(contentIDs: [])
        let list = params["content_id_list"] as? [[String: String]]
        XCTAssertEqual(list?.count, 0)
    }

    func testChangeMatteCommand() {
        let params = SamsungArtProtocol.changeMatte(contentID: "c1", matteID: "shadowbox_polar")
        XCTAssertEqual(params["request"] as? String, "change_matte")
        XCTAssertEqual(params["content_id"] as? String, "c1")
        XCTAssertEqual(params["matte_id"] as? String, "shadowbox_polar")
        XCTAssertNil(params["portrait_matte_id"], "portrait_matte_id should not be set when nil")
    }

    func testChangeMatteWithPortrait() {
        let params = SamsungArtProtocol.changeMatte(contentID: "c1", matteID: "shadowbox_polar", portraitMatteID: "flexible_warm")
        XCTAssertEqual(params["portrait_matte_id"] as? String, "flexible_warm")
    }

    func testSlideshowStatusOff() {
        let params = SamsungArtProtocol.setSlideshowStatus(durationMinutes: 0, shuffle: false)
        XCTAssertEqual(params["request"] as? String, "set_slideshow_status")
        XCTAssertEqual(params["value"] as? String, "off")
        XCTAssertEqual(params["type"] as? String, "slideshow")
        XCTAssertEqual(params["category_id"] as? String, "MY-C0002")
    }

    func testSlideshowStatusShuffleOn() {
        let params = SamsungArtProtocol.setSlideshowStatus(durationMinutes: 15, shuffle: true)
        XCTAssertEqual(params["value"] as? String, "15")
        XCTAssertEqual(params["type"] as? String, "shuffleslideshow")
    }

    func testSlideshowStatusCustomCategory() {
        let params = SamsungArtProtocol.setSlideshowStatus(durationMinutes: 30, shuffle: false, categoryID: "MY-C0003")
        XCTAssertEqual(params["category_id"] as? String, "MY-C0003")
    }

    func testGetSlideshowStatus() {
        let params = SamsungArtProtocol.getSlideshowStatus()
        XCTAssertEqual(params["request"] as? String, "get_slideshow_status")
    }

    func testGetMatteList() {
        let params = SamsungArtProtocol.getMatteList()
        XCTAssertEqual(params["request"] as? String, "get_matte_list")
    }

    func testGetDeviceInfo() {
        let params = SamsungArtProtocol.getDeviceInfo()
        XCTAssertEqual(params["request"] as? String, "get_device_info")
    }

    func testChangeFavoriteOn() {
        let params = SamsungArtProtocol.changeFavorite(contentID: "c1", on: true)
        XCTAssertEqual(params["request"] as? String, "change_favorite")
        XCTAssertEqual(params["content_id"] as? String, "c1")
        XCTAssertEqual(params["status"] as? String, "on")
    }

    func testChangeFavoriteOff() {
        let params = SamsungArtProtocol.changeFavorite(contentID: "c1", on: false)
        XCTAssertEqual(params["status"] as? String, "off")
    }

    // MARK: - API Version

    func testAPIVersionNewAPI() {
        let params = SamsungArtProtocol.getAPIVersion(useNewAPI: true)
        XCTAssertEqual(params["request"] as? String, "api_version")
    }

    func testAPIVersionOldAPI() {
        let params = SamsungArtProtocol.getAPIVersion(useNewAPI: false)
        XCTAssertEqual(params["request"] as? String, "get_api_version")
    }

    // MARK: - Send Image (Upload)

    /// Samsung rejects "jpeg" — must convert to "jpg".
    func testSendImageJPEGtoJPG() {
        let (params, _) = SamsungArtProtocol.sendImage(
            fileType: "jpeg", fileSize: 1024, matteID: "none", portraitMatteID: "none"
        )
        XCTAssertEqual(params["file_type"] as? String, "jpg",
                       "jpeg must be converted to jpg for Samsung")
    }

    func testSendImageJPEGCaseInsensitive() {
        let (params, _) = SamsungArtProtocol.sendImage(
            fileType: "JPEG", fileSize: 1024, matteID: "none", portraitMatteID: "none"
        )
        XCTAssertEqual(params["file_type"] as? String, "jpg")
    }

    /// Critical: id, request_id, and conn_info.id must ALL be the same UUID.
    /// If they don't match, the TV won't correlate the upload response.
    func testSendImageTripleUUIDMatch() {
        let (params, uuid) = SamsungArtProtocol.sendImage(
            fileType: "jpg", fileSize: 1024, matteID: "none", portraitMatteID: "none"
        )

        XCTAssertEqual(params["id"] as? String, uuid)
        XCTAssertEqual(params["request_id"] as? String, uuid)

        let connInfo = params["conn_info"] as? [String: Any]
        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?["id"] as? String, uuid,
                       "conn_info.id must match outer id (Python: self.art_uuid used for all three)")
        XCTAssertEqual(connInfo?["d2d_mode"] as? String, "socket")
    }

    func testSendImageAllFields() {
        let (params, _) = SamsungArtProtocol.sendImage(
            fileType: "jpg", fileSize: 2048000,
            matteID: "flexible_warm", portraitMatteID: "shadowbox_polar"
        )

        XCTAssertEqual(params["request"] as? String, "send_image")
        XCTAssertEqual(params["file_size"] as? Int, 2048000)
        XCTAssertEqual(params["matte_id"] as? String, "flexible_warm")
        XCTAssertEqual(params["portrait_matte_id"] as? String, "shadowbox_polar")
        XCTAssertNotNil(params["image_date"] as? String)

        let connInfo = params["conn_info"] as? [String: Any]
        XCTAssertNotNil(connInfo?["connection_id"] as? Int)
    }

    func testSendImageUUIDIsLowercase() {
        let (_, uuid) = SamsungArtProtocol.sendImage(
            fileType: "jpg", fileSize: 1024, matteID: "none", portraitMatteID: "none"
        )
        XCTAssertEqual(uuid, uuid.lowercased())
    }

    // MARK: - Upload Header

    func testUploadHeaderStructure() {
        let header = SamsungArtProtocol.uploadHeader(fileSize: 5000, fileType: "jpg", secKey: "abc123")
        XCTAssertEqual(header["num"] as? Int, 0)
        XCTAssertEqual(header["total"] as? Int, 1)
        XCTAssertEqual(header["fileLength"] as? Int, 5000)
        XCTAssertEqual(header["fileName"] as? String, "dummy")
        XCTAssertEqual(header["fileType"] as? String, "jpg")
        XCTAssertEqual(header["secKey"] as? String, "abc123")
        XCTAssertEqual(header["version"] as? String, "0.0.1")
    }

    func testUploadHeaderJPEGConversion() {
        let header = SamsungArtProtocol.uploadHeader(fileSize: 5000, fileType: "JPEG", secKey: "key")
        XCTAssertEqual(header["fileType"] as? String, "jpg")
    }

    /// Header must serialize to valid JSON for the TCP socket.
    func testUploadHeaderSerializable() throws {
        let header = SamsungArtProtocol.uploadHeader(fileSize: 5000, fileType: "jpg", secKey: "key")
        let data = try JSONSerialization.data(withJSONObject: header)
        XCTAssertGreaterThan(data.count, 0)

        // Verify round-trip
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["fileLength"] as? Int, 5000)
    }

    // MARK: - Thumbnail Command

    func testThumbnailListCommand() {
        let ids = ["content1", "content2"]
        let (params, connUUID) = SamsungArtProtocol.getThumbnailList(contentIDs: ids)

        XCTAssertEqual(params["request"] as? String, "get_thumbnail_list")

        let list = params["content_id_list"] as? [[String: String]]
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?[0]["content_id"], "content1")
        XCTAssertEqual(list?[1]["content_id"], "content2")

        let connInfo = params["conn_info"] as? [String: Any]
        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?["d2d_mode"] as? String, "socket")
        XCTAssertEqual(connInfo?["id"] as? String, connUUID)
    }

    /// For thumbnails, conn_info.id is independent from the outer request UUID.
    /// Python: get_uuid() generates a new one each time.
    func testThumbnailConnUUIDIsIndependent() {
        let (params, connUUID) = SamsungArtProtocol.getThumbnailList(contentIDs: ["c1"])

        // If we wrap this in buildEnvelope, the outer UUID will be different
        // from the conn_info UUID (unlike upload where they must match).
        let connInfo = params["conn_info"] as? [String: Any]
        XCTAssertEqual(connInfo?["id"] as? String, connUUID)
        // The outer id/request_id will be injected by buildEnvelope separately
    }

    // MARK: - URL Builders

    func testRemoteControlURLSSL() {
        let url = SamsungArtProtocol.remoteControlURL(host: "192.168.1.100", port: 8002, token: "mytoken")
        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.hasPrefix("wss://"), "Port 8002 must use wss://")
        XCTAssertTrue(urlString.contains("samsung.remote.control"))
        XCTAssertTrue(urlString.contains("token=mytoken"))

        // Name should be base64-encoded "LightFrame"
        let b64 = Data("LightFrame".utf8).base64EncodedString()
        XCTAssertTrue(urlString.contains("name=\(b64)"))
    }

    func testArtChannelURLNoToken() {
        let url = SamsungArtProtocol.artChannelURL(host: "192.168.1.100", port: 8002)
        XCTAssertNotNil(url)
        let urlString = url!.absoluteString
        XCTAssertTrue(urlString.hasPrefix("wss://"))
        XCTAssertTrue(urlString.contains("com.samsung.art-app"))
        XCTAssertFalse(urlString.contains("token="))
    }

    func testNonSSLURL() {
        let url = SamsungArtProtocol.websocketURL(host: "192.168.1.100", port: 8001, endpoint: "samsung.remote.control")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.hasPrefix("ws://"), "Port 8001 must use ws://")
    }

    func testURLContainsPort() {
        let url = SamsungArtProtocol.websocketURL(host: "192.168.1.100", port: 8002, endpoint: "test")
        XCTAssertTrue(url!.absoluteString.contains(":8002"))
    }

    // MARK: - Random Connection ID

    func testRandomConnectionIDRange() {
        // Python: random.randrange(4 * 1024 * 1024 * 1024) → 0..<4294967296
        for _ in 0..<100 {
            let id = SamsungArtProtocol.randomConnectionID()
            XCTAssertGreaterThanOrEqual(id, 0)
            XCTAssertLessThan(id, Int(UInt32.max))
        }
    }

    // MARK: - Helpers

    private nonisolated func parseJSON(_ jsonString: String) throws -> [String: Any] {
        let data = jsonString.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private nonisolated func extractInner(from envelope: String) throws -> [String: Any] {
        let outer = try parseJSON(envelope)
        let params = outer["params"] as! [String: Any]
        let dataString = params["data"] as! String
        return try parseJSON(dataString)
    }
}
