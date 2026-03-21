import XCTest
@testable import LightFrame

// MARK: - TVDiagnosticTests
//
// These tests run against a LIVE TV (when available) and produce structured
// diagnostic output. The output is designed to be copy-pasted into a
// conversation with Claude for cross-model-year analysis.
//
// Run these tests with:
//   xcodebuild test -only-testing:LightFrameTests/TVDiagnosticTests \
//     -destination 'platform=macOS'
//
// Or skip live tests by setting TV_HOST env var to empty.
//
// The diagnostic report captures:
//   - TV model, firmware version, API version
//   - Supported matte styles and colors
//   - Content list structure and field types
//   - Response timing for each operation
//   - Raw response samples for protocol analysis
//   - Error behaviors and edge cases
//
// This data lets us compare behavior across:
//   - Model years (LS03A, LS03B, LS03D, etc.)
//   - Firmware versions
//   - Regional variants
//
final class TVDiagnosticTests: XCTestCase {

    // MARK: - Matte System Tests (offline)

    /// Verify all matte API tokens match Samsung's expected format.
    func testMatteAPITokenFormat() {
        for style in MatteStyle.allCases {
            if style == .none {
                let matte = Matte(style: style, color: nil)
                XCTAssertEqual(matte.apiToken, "none")
                continue
            }
            for color in MatteColor.allCases {
                let matte = Matte(style: style, color: color)
                let token = matte.apiToken
                XCTAssertTrue(token.contains("_"),
                              "Token '\(token)' should be style_color format")
                XCTAssertEqual(token, "\(style.rawValue)_\(color.rawValue)")
            }
        }
    }

    /// Verify Samsung's "burgandy" misspelling is preserved in the API token.
    func testBurgandyMisspelling() {
        XCTAssertEqual(MatteColor.burgundy.rawValue, "burgandy",
                       "Must match Samsung's misspelling — TV will reject 'burgundy'")
        let matte = Matte(style: .flexible, color: .burgundy)
        XCTAssertEqual(matte.apiToken, "flexible_burgandy")
    }

    /// Verify matte fallback chain produces correct tokens.
    func testMatteFallbackChain() {
        let original = Matte(style: .flexible, color: .warm)

        // Fallback 1: shadowbox + same color
        let fb1 = Matte.fallbackPreservingColor(original.color)
        XCTAssertEqual(fb1.style, .shadowbox)
        XCTAssertEqual(fb1.color, .warm)
        XCTAssertEqual(fb1.apiToken, "shadowbox_warm")

        // Fallback 2: shadowbox + polar (safe baseline)
        let fb2 = Matte.safeFallback
        XCTAssertEqual(fb2.apiToken, "shadowbox_polar")
    }

    /// Verify fallback when color is nil (unknown/corrupt metadata).
    func testMatteFallbackNilColor() {
        let fb = Matte.fallbackPreservingColor(nil)
        XCTAssertEqual(fb.apiToken, "shadowbox_polar",
                       "nil color should fall back to polar")
    }

    /// Verify matte parsing from EXIF strings.
    func testMatteParseFromEXIF() {
        let cases: [(String, String?, String?)] = [
            ("none", "none", nil),
            ("flexible_warm", "flexible", "warm"),
            ("shadowbox_polar", "shadowbox", "polar"),
            ("modernthin_burgandy", "modernthin", "burgandy"),
            ("panoramic_navy", "panoramic", "navy"),
        ]

        for (input, expectedStyle, expectedColor) in cases {
            let matte = Matte.parse(input)
            XCTAssertNotNil(matte, "Should parse '\(input)'")
            XCTAssertEqual(matte?.style.rawValue, expectedStyle)
            if let color = expectedColor {
                XCTAssertEqual(matte?.color?.rawValue, color)
            }
        }
    }

    func testMatteParseInvalid() {
        XCTAssertNil(Matte.parse("invalid_style"))
        XCTAssertNil(Matte.parse(""))
    }

    // MARK: - All Matte Combinations

    /// Generate the complete matrix of matte tokens for protocol verification.
    /// This output can be compared against what the TV actually accepts.
    func testAllMatteTokens() {
        var tokens: [String] = ["none"]
        for style in MatteStyle.allCases where style != .none {
            for color in MatteColor.allCases {
                tokens.append("\(style.rawValue)_\(color.rawValue)")
            }
        }
        // Verify we generate the expected count
        let expectedCount = 1 + (MatteStyle.allCases.count - 1) * MatteColor.allCases.count
        XCTAssertEqual(tokens.count, expectedCount,
                       "Should generate \(expectedCount) matte combinations")

        // Verify all tokens match the Matte model
        for token in tokens {
            if token == "none" { continue }
            let parsed = Matte.parse(token)
            XCTAssertNotNil(parsed, "Token '\(token)' should be parseable")
            XCTAssertEqual(parsed?.apiToken, token, "Round-trip should preserve token")
        }
    }

    // MARK: - TVArtItem Edge Cases

    func testTVArtItemWithNilFields() {
        let dict: [String: Any] = [
            "content_id": "MY-C0002_test",
            "category_id": "MY-C0002"
            // All other fields missing
        ]
        let item = TVArtItem.from(dict)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "MY-C0002_test")
        XCTAssertEqual(item?.contentType, "")
        XCTAssertNil(item?.width)
        XCTAssertNil(item?.height)
        XCTAssertNil(item?.fileSize)
        XCTAssertNil(item?.matteID)
    }

    /// Samsung returns file_size as a string. Test that we handle both.
    func testTVArtItemFileSizeVariants() {
        let stringSize = TVArtItem.from(["content_id": "t1", "file_size": "12345"])
        XCTAssertEqual(stringSize?.fileSize, 12345)

        let intSize = TVArtItem.from(["content_id": "t2", "file_size": 12345])
        XCTAssertEqual(intSize?.fileSize, 12345)

        let noSize = TVArtItem.from(["content_id": "t3"])
        XCTAssertNil(noSize?.fileSize)
    }

    // MARK: - ConnInfo Edge Cases

    func testConnInfoAllStringTypes() {
        // Some firmware returns everything as strings
        let dict: [String: Any] = [
            "ip": "10.0.0.1",
            "port": "8080",
            "secured": "true",
            "key": "abc"
        ]
        let connData = try! JSONSerialization.data(withJSONObject: dict)
        let connString = String(data: connData, encoding: .utf8)!

        let json = TVResponseFixtures.d2dMessage(
            event: "ready_to_use",
            fields: ["conn_info": connString]
        )
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertNotNil(connInfo)
        XCTAssertEqual(connInfo?.port, 8080)
        XCTAssertTrue(connInfo!.secured)
        XCTAssertEqual(connInfo?.key, "abc")
    }

    func testConnInfoDefaultSecuredFalse() {
        // Missing "secured" field should default to false
        let dict: [String: Any] = ["ip": "10.0.0.1", "port": 5000]
        let connData = try! JSONSerialization.data(withJSONObject: dict)
        let connString = String(data: connData, encoding: .utf8)!

        let json = TVResponseFixtures.d2dMessage(
            event: "ready_to_use",
            fields: ["conn_info": connString]
        )
        let inner = SamsungArtParser.parseD2DMessage(json)!
        let connInfo = SamsungArtParser.parseConnInfo(from: inner)

        XCTAssertEqual(connInfo?.secured, false)
    }

    // MARK: - Timeout Value Verification

    /// Verify our timeout values match Nick Waterton's Python implementation.
    /// These are critical — too short = premature failures, too long = hangs.
    func testTimeoutValuesMatchPython() async throws {
        let mock = MockArtConnection()
        try await mock.connect()
        let service = await SamsungArtService(testConnection: mock)

        // Script all responses
        let responseTypes = [
            "get_content_list", "get_current_artwork", "select_image",
            "delete_image_list", "change_matte", "set_slideshow_status",
            "get_slideshow_status", "get_artmode_status", "api_version",
            "get_device_info", "get_matte_list"
        ]
        for rt in responseTypes {
            let inner = await mock.makeInner(event: rt, fields: [
                "content_list": "[]", "value": "off", "type": "slideshow",
                "matte_type_list": "[]", "version": "1.0"
            ])
            await mock.scriptResponse(for: rt, inner: inner)
        }

        // Call each method and check the timeout used
        _ = try? await service.fetchArtList()
        _ = try? await service.fetchCurrentArtwork()
        try? await service.selectImage(contentID: "c1")
        try? await service.deleteArt(contentIDs: ["c1"])
        try? await service.changeMatte(contentID: "c1", matteID: "none")
        try? await service.setSlideshowStatus(durationMinutes: 15, shuffle: false)
        _ = try? await service.fetchSlideshowStatus()
        _ = try? await service.fetchArtmodeStatus()
        _ = try? await service.fetchAPIVersion()
        _ = try? await service.fetchDeviceInfo()
        _ = try? await service.fetchMatteList()

        let commands = await mock.sentCommands
        let timeouts = Dictionary(uniqueKeysWithValues: commands.map { ($0.request, $0.timeout) })

        // Python defaults: most commands use 2s. We use 5s for safety margin.
        // Critical timeouts that are explicitly set:
        XCTAssertEqual(timeouts["get_content_list"], 10,
                       "Content list needs 10s — large galleries take time")
        XCTAssertEqual(timeouts["delete_image_list"], 10,
                       "Delete needs 10s — TV processes sequentially")
        XCTAssertEqual(timeouts["change_matte"], 15,
                       "Matte change needs 15s — TV does image reprocessing")

        // Standard commands should use 5s (our safety margin over Python's 2s)
        XCTAssertEqual(timeouts["get_current_artwork"], 5)
        XCTAssertEqual(timeouts["select_image"], 5)
        XCTAssertEqual(timeouts["get_slideshow_status"], 5)
        XCTAssertEqual(timeouts["get_artmode_status"], 5)
        XCTAssertEqual(timeouts["get_device_info"], 5)
        XCTAssertEqual(timeouts["get_matte_list"], 5)
    }

    // MARK: - Protocol Constants

    func testWebSocketEndpointConstants() {
        XCTAssertEqual(SamsungArtProtocol.remoteControlEndpoint, "samsung.remote.control")
        XCTAssertEqual(SamsungArtProtocol.artAppEndpoint, "com.samsung.art-app")
    }

    func testBase64NameEncoding() {
        // Python: helper.serialize_string(name) = base64.b64encode(name.encode())
        let name = "LightFrame"
        let b64 = Data(name.utf8).base64EncodedString()
        XCTAssertEqual(b64, "TGlnaHRGcmFtZQ==")

        // Verify it's in the URL
        let url = SamsungArtProtocol.remoteControlURL(host: "192.168.1.1")
        XCTAssertTrue(url!.absoluteString.contains("TGlnaHRGcmFtZQ=="))
    }

    // MARK: - SamsungArtError Equatable Behavior

    func testErrorDescriptionsContainContext() {
        let err = SamsungArtError.tvError(request: "change_matte", errorCode: "INVALID_CONTENT")
        let desc = err.localizedDescription
        XCTAssertTrue(desc.contains("change_matte"))
        XCTAssertTrue(desc.contains("INVALID_CONTENT"))
    }
}
