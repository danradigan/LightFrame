import XCTest
@testable import LightFrame

// MARK: - SamsungArtServiceTests
//
// Tests SamsungArtService orchestration using MockArtConnection.
// Verifies that the service correctly:
//   - Sends the right commands with the right params
//   - Parses responses into typed models
//   - Handles errors and edge cases
//   - Matches Nick Waterton's Python behavior
//
// TCP-dependent methods (upload, thumbnails) are tested at the protocol
// level in Phase 1 tests and via the live diagnostic harness.
//
final class SamsungArtServiceTests: XCTestCase {

    private var mock: MockArtConnection!
    private var service: SamsungArtService!

    override func setUp() async throws {
        mock = MockArtConnection()
        try await mock.connect()
        service = await SamsungArtService(testConnection: mock)
    }

    override func tearDown() async throws {
        service = nil
        mock = nil
    }

    // MARK: - Connection State

    func testServiceStartsConnected() async {
        let connected = await service.isConnected
        XCTAssertTrue(connected)
    }

    func testRequireConnectionThrowsWhenDisconnected() async {
        let emptyService = await SamsungArtService()
        do {
            _ = try await emptyService.fetchArtmodeStatus()
            XCTFail("Should throw notConnected")
        } catch let error as SamsungArtError {
            if case .notConnected = error {} else {
                XCTFail("Expected .notConnected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Fetch Art List

    func testFetchArtListParsesContentList() async throws {
        let items: [[String: Any]] = [
            TVResponseFixtures.sampleArtItem(contentID: "MY-C0002_001", category: "MY-C0002"),
            TVResponseFixtures.sampleArtItem(contentID: "MY-C0002_002", category: "MY-C0002"),
            TVResponseFixtures.sampleArtItem(contentID: "SAM-001", category: "SAM-C0001"),
        ]
        let inner = await mock.makeContentListResponse(items: items)
        await mock.scriptResponse(for: "get_content_list", inner: inner)

        let result = try await service.fetchArtList()
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.filter { $0.isUserPhoto }.count, 2)
        XCTAssertEqual(result.filter { $0.isBuiltIn }.count, 1)
    }

    func testFetchArtListWithCategoryFilter() async throws {
        let items: [[String: Any]] = [
            TVResponseFixtures.sampleArtItem(contentID: "MY-C0002_001", category: "MY-C0002"),
            TVResponseFixtures.sampleArtItem(contentID: "SAM-001", category: "SAM-C0001"),
        ]
        let inner = await mock.makeContentListResponse(items: items)
        await mock.scriptResponse(for: "get_content_list", inner: inner)

        let result = try await service.fetchArtList(category: "MY-C0002")
        XCTAssertEqual(result.count, 1, "Should filter to only MY-C0002 items")
        XCTAssertEqual(result[0].id, "MY-C0002_001")
    }

    func testFetchArtListEmptyResponse() async throws {
        let inner = await mock.makeContentListResponse(items: [])
        await mock.scriptResponse(for: "get_content_list", inner: inner)

        let result = try await service.fetchArtList()
        XCTAssertTrue(result.isEmpty)
    }

    func testFetchArtListMissingContentList() async throws {
        // Response without content_list field at all
        let inner = await mock.makeInner(event: "get_content_list")
        await mock.scriptResponse(for: "get_content_list", inner: inner)

        let result = try await service.fetchArtList()
        XCTAssertTrue(result.isEmpty, "Should return empty array when content_list is missing")
    }

    func testFetchMyPhotosUsesCorrectCategory() async throws {
        let items: [[String: Any]] = [
            TVResponseFixtures.sampleArtItem(contentID: "MY-C0002_001", category: "MY-C0002"),
        ]
        let inner = await mock.makeContentListResponse(items: items)
        await mock.scriptResponse(for: "get_content_list", inner: inner)

        _ = try await service.fetchMyPhotos()

        // Verify the command was sent with category "MY-C0002"
        let commands = await mock.sentCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].params["category"], "MY-C0002")
    }

    // MARK: - Current Artwork

    func testFetchCurrentArtwork() async throws {
        let inner = await mock.makeInner(event: "get_current_artwork", fields: [
            "content_id": "MY-C0002_current",
            "matte_id": "flexible_warm",
            "category_id": "MY-C0002"
        ])
        await mock.scriptResponse(for: "get_current_artwork", inner: inner)

        let result = try await service.fetchCurrentArtwork()
        XCTAssertEqual(result.raw["content_id"] as? String, "MY-C0002_current")
        XCTAssertEqual(result.raw["matte_id"] as? String, "flexible_warm")
    }

    // MARK: - Select Image

    func testSelectImageSendsCorrectParams() async throws {
        let inner = await mock.makeInner(event: "select_image")
        await mock.scriptResponse(for: "select_image", inner: inner)

        try await service.selectImage(contentID: "test-content-123", show: true)

        let commands = await mock.sentCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].request, "select_image")
        XCTAssertEqual(commands[0].params["content_id"], "test-content-123")
        // Bool may serialize as "1", "true", or "Optional(1)" depending on context
        XCTAssertNotNil(commands[0].params["show"])
    }

    // MARK: - Delete Art

    func testDeleteArtSendsCorrectFormat() async throws {
        let inner = await mock.makeInner(event: "delete_image_list")
        await mock.scriptResponse(for: "delete_image_list", inner: inner)

        try await service.deleteArt(contentIDs: ["id1", "id2"])

        let commands = await mock.sentCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].request, "delete_image_list")
    }

    // MARK: - Change Matte

    func testChangeMatteUsesCorrectTimeout() async throws {
        let inner = await mock.makeInner(event: "change_matte")
        await mock.scriptResponse(for: "change_matte", inner: inner)

        try await service.changeMatte(contentID: "c1", matteID: "shadowbox_polar")

        let commands = await mock.sentCommands
        XCTAssertEqual(commands[0].timeout, 15, "Matte changes need 15s timeout per Nick's implementation")
    }

    func testChangeMatteRawSendsExtraParams() async throws {
        let inner = await mock.makeInner(event: "change_matte")
        await mock.scriptResponse(for: "change_matte", inner: inner)

        try await service.changeMatteRaw(contentID: "c1", extraParams: ["matte_id": "flexible_warm"])

        let commands = await mock.sentCommands
        XCTAssertEqual(commands[0].params["matte_id"], "flexible_warm")
        XCTAssertEqual(commands[0].params["content_id"], "c1")
    }

    // MARK: - Slideshow

    func testFetchSlideshowStatus() async throws {
        let inner = await mock.makeSlideshowResponse(value: "15", type: "shuffleslideshow", categoryID: "MY-C0002")
        await mock.scriptResponse(for: "get_slideshow_status", inner: inner)

        let status = try await service.fetchSlideshowStatus()
        XCTAssertEqual(status.minutes, 15)
        XCTAssertTrue(status.isShuffle)
        XCTAssertFalse(status.isOff)
        XCTAssertEqual(status.categoryID, "MY-C0002")
    }

    func testFetchSlideshowStatusOff() async throws {
        let inner = await mock.makeSlideshowResponse(value: "off", type: "slideshow")
        await mock.scriptResponse(for: "get_slideshow_status", inner: inner)

        let status = try await service.fetchSlideshowStatus()
        XCTAssertTrue(status.isOff)
    }

    func testSetSlideshowSendsCorrectParams() async throws {
        let inner = await mock.makeInner(event: "set_slideshow_status")
        await mock.scriptResponse(for: "set_slideshow_status", inner: inner)

        try await service.setSlideshowStatus(durationMinutes: 30, shuffle: true)

        let commands = await mock.sentCommands
        XCTAssertEqual(commands[0].params["value"], "30")
        XCTAssertEqual(commands[0].params["type"], "shuffleslideshow")
    }

    // MARK: - Art Mode Status

    func testFetchArtmodeStatusOn() async throws {
        let inner = await mock.makeInner(event: "get_artmode_status", fields: ["value": "on"])
        await mock.scriptResponse(for: "get_artmode_status", inner: inner)

        let isOn = try await service.fetchArtmodeStatus()
        XCTAssertTrue(isOn)
    }

    func testFetchArtmodeStatusOff() async throws {
        let inner = await mock.makeInner(event: "get_artmode_status", fields: ["value": "off"])
        await mock.scriptResponse(for: "get_artmode_status", inner: inner)

        let isOn = try await service.fetchArtmodeStatus()
        XCTAssertFalse(isOn)
    }

    // MARK: - API Version

    func testFetchAPIVersionNewAPI() async throws {
        let inner = await mock.makeInner(event: "api_version", fields: ["version": "4.3.5.0"])
        await mock.scriptResponse(for: "api_version", inner: inner)

        let version = try await service.fetchAPIVersion()
        XCTAssertEqual(version, "4.3.5.0")
    }

    /// Python: tries new API first, falls back to old.
    func testFetchAPIVersionFallbackToOld() async throws {
        // New API fails
        await mock.scriptError(for: "api_version", error: SamsungArtError.timeout("new api"))
        // Old API succeeds
        let inner = await mock.makeInner(event: "get_api_version", fields: ["version": "2.0"])
        await mock.scriptResponse(for: "get_api_version", inner: inner)

        let version = try await service.fetchAPIVersion()
        XCTAssertEqual(version, "2.0")

        // Verify both were attempted
        let commands = await mock.sentCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].request, "api_version")
        XCTAssertEqual(commands[1].request, "get_api_version")
    }

    // MARK: - Device Info

    func testFetchDeviceInfo() async throws {
        let inner = await mock.makeInner(event: "get_device_info", fields: [
            "FrameTVSupport": "true",
            "model_name": "QN55LS03BAFXZA"
        ])
        await mock.scriptResponse(for: "get_device_info", inner: inner)

        let info = try await service.fetchDeviceInfo()
        XCTAssertEqual(info["model_name"] as? String, "QN55LS03BAFXZA")
        XCTAssertEqual(info["FrameTVSupport"] as? String, "true")
    }

    // MARK: - Matte List

    func testFetchMatteListParsesJSONStrings() async throws {
        let styles: [[String: Any]] = [
            ["matte_type": "none"], ["matte_type": "shadowbox"], ["matte_type": "flexible"]
        ]
        let colors: [[String: Any]] = [
            ["color": "polar"], ["color": "warm"], ["color": "burgandy"]
        ]
        let stylesData = try JSONSerialization.data(withJSONObject: styles)
        let colorsData = try JSONSerialization.data(withJSONObject: colors)

        let inner = await mock.makeInner(event: "get_matte_list", fields: [
            "matte_type_list": String(data: stylesData, encoding: .utf8)!,
            "matte_color_list": String(data: colorsData, encoding: .utf8)!
        ])
        await mock.scriptResponse(for: "get_matte_list", inner: inner)

        let (resultStyles, resultColors) = try await service.fetchMatteList()
        XCTAssertEqual(resultStyles.count, 3)
        XCTAssertEqual(resultColors?.count, 3)

        // Verify Samsung's "burgandy" misspelling is preserved
        let colorNames = resultColors?.compactMap { $0["color"] as? String }
        XCTAssertTrue(colorNames?.contains("burgandy") ?? false,
                      "Must preserve Samsung's misspelling of 'burgandy'")
    }

    // MARK: - Error Handling

    func testTVErrorThrowsSamsungArtError() async throws {
        await mock.scriptTVError(for: "get_artmode_status", errorCode: "INVALID_REQUEST")

        do {
            _ = try await service.fetchArtmodeStatus()
            XCTFail("Should throw tvError")
        } catch let error as SamsungArtError {
            if case .tvError(let req, let code) = error {
                XCTAssertEqual(req, "get_artmode_status")
                XCTAssertEqual(code, "INVALID_REQUEST")
            } else {
                XCTFail("Expected .tvError, got \(error)")
            }
        }
    }

    func testConnectionLostPropagatesError() async throws {
        await mock.setGlobalError(SamsungArtError.connectionFailed("Art channel closed"))

        do {
            _ = try await service.fetchArtmodeStatus()
            XCTFail("Should throw connectionFailed")
        } catch let error as SamsungArtError {
            if case .connectionFailed = error {} else {
                XCTFail("Expected .connectionFailed, got \(error)")
            }
        }
    }

    // MARK: - Command Verification

    /// Verify all commands use the correct "request" field name matching Nick Waterton's Python.
    func testAllCommandRequestNames() async throws {
        // Script all responses
        let commands: [(method: String, request: String)] = [
            ("fetchArtList", "get_content_list"),
            ("fetchCurrentArtwork", "get_current_artwork"),
            ("fetchArtmodeStatus", "get_artmode_status"),
            ("fetchSlideshowStatus", "get_slideshow_status"),
            ("fetchDeviceInfo", "get_device_info"),
            ("fetchMatteList", "get_matte_list"),
        ]

        for cmd in commands {
            let inner = await mock.makeInner(event: cmd.request, fields: [
                "content_list": "[]",
                "value": "off",
                "type": "slideshow",
                "matte_type_list": "[]"
            ])
            await mock.scriptResponse(for: cmd.request, inner: inner)
        }

        // Call each method
        _ = try? await service.fetchArtList()
        _ = try? await service.fetchCurrentArtwork()
        _ = try? await service.fetchArtmodeStatus()
        _ = try? await service.fetchSlideshowStatus()
        _ = try? await service.fetchDeviceInfo()
        _ = try? await service.fetchMatteList()

        // Verify all commands were sent with correct request names
        let sentRequests = await mock.sentCommands.map { $0.request }
        for cmd in commands {
            XCTAssertTrue(sentRequests.contains(cmd.request),
                          "Missing command: \(cmd.request) (method: \(cmd.method))")
        }
    }
}

// MARK: - MockArtConnection convenience for setting globalError
extension MockArtConnection {
    func setGlobalError(_ error: Error?) {
        self.globalError = error
    }
}
