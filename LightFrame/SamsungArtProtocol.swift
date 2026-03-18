import Foundation

// MARK: - SamsungArtProtocol
//
// Owns command envelope construction, matching NickWaterton/samsung-tv-ws-api art.py.
//
// Python reference: ArtChannelEmitCommand.art_app_request() + _send_art_request()
//
// Envelope shape:
//   {
//     "method": "ms.channel.emit",
//     "params": {
//       "event": "art_app_request",
//       "to": "host",
//       "data": "<JSON string of inner payload>"   ← double-encoded
//     }
//   }
//
// Inner payload always includes both "id" (old API) and "request_id" (new API),
// set to the same lowercase UUID.

enum SamsungArtProtocol {

    // MARK: - UUID Generation
    // Python: str(uuid.uuid4()) → lowercase hex with hyphens
    // Swift UUID().uuidString is uppercase — we must lowercase it.
    nonisolated static func generateUUID() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: - Random Connection ID
    // Python: random.randrange(4 * 1024 * 1024 * 1024) → 0..<4294967296
    nonisolated static func randomConnectionID() -> Int {
        Int(UInt32.random(in: 0 ..< UInt32.max))
    }

    // MARK: - Build Envelope
    //
    // Wraps an inner payload dict into the ms.channel.emit envelope.
    // Automatically injects id and request_id if not already present.
    //
    // Python equivalent:
    //   if not request_data.get("id"):
    //       request_data["id"] = self.get_uuid()          # old api
    //   request_data["request_id"] = request_data["id"]   # new api
    //   ArtChannelEmitCommand.art_app_request(request_data)
    //
    // Returns: (envelopeJSONString, requestUUID)
    //
    nonisolated static func buildEnvelope(_ innerParams: [String: Any], uuid: String? = nil) throws -> (String, String) {
        var params = innerParams
        let requestUUID = uuid ?? (params["id"] as? String) ?? generateUUID()
        params["id"] = requestUUID
        params["request_id"] = requestUUID

        guard let innerData = try? JSONSerialization.data(withJSONObject: params),
              let innerString = String(data: innerData, encoding: .utf8)
        else {
            throw SamsungArtError.encodingFailed("Could not encode inner params")
        }

        let envelope: [String: Any] = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to": "host",
                "data": innerString
            ]
        ]

        guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope),
              let envelopeString = String(data: envelopeData, encoding: .utf8)
        else {
            throw SamsungArtError.encodingFailed("Could not encode envelope")
        }

        return (envelopeString, requestUUID)
    }

    // MARK: - Command Builders
    // Each returns the inner payload dict. Caller wraps with buildEnvelope().
    // These match the Python method signatures and payload shapes exactly.

    // Python: available(category=None) → {"request": "get_content_list", "category": category}
    static func getContentList(category: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["request": "get_content_list"]
        params["category"] = category as Any? ?? NSNull()
        return params
    }

    // Python: get_current_artwork() → {"request": "get_current_artwork"}
    static func getCurrentArtwork() -> [String: Any] {
        ["request": "get_current_artwork"]
    }

    // Python: get_api_version() → {"request": "api_version"} (new) or {"request": "get_api_version"} (old)
    static func getAPIVersion(useNewAPI: Bool = true) -> [String: Any] {
        ["request": useNewAPI ? "api_version" : "get_api_version"]
    }

    // Python: get_device_info() → {"request": "get_device_info"}
    static func getDeviceInfo() -> [String: Any] {
        ["request": "get_device_info"]
    }

    // Python: get_artmode_status() → {"request": "get_artmode_status"}
    static func getArtmodeStatus() -> [String: Any] {
        ["request": "get_artmode_status"]
    }

    // Python: set_artmode_status(mode) → {"request": "set_artmode_status", "value": "on"/"off"}
    static func setArtmodeStatus(on: Bool) -> [String: Any] {
        ["request": "set_artmode_status", "value": on ? "on" : "off"]
    }

    // Python: select_image(content_id, category=None, show=True)
    static func selectImage(contentID: String, category: String? = nil, show: Bool = true) -> [String: Any] {
        var params: [String: Any] = [
            "request": "select_image",
            "content_id": contentID,
            "show": show
        ]
        params["category_id"] = category as Any? ?? NSNull()
        return params
    }

    // Python: delete_image_list(content_ids)
    // Builds [{"content_id": id}, ...] — NOT [id, ...]
    static func deleteImageList(contentIDs: [String]) -> [String: Any] {
        let list = contentIDs.map { ["content_id": $0] }
        return [
            "request": "delete_image_list",
            "content_id_list": list
        ]
    }

    // Python: change_matte(content_id, matte_id, portrait_matte)
    static func changeMatte(contentID: String, matteID: String, portraitMatteID: String? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "request": "change_matte",
            "content_id": contentID,
            "matte_id": matteID
        ]
        if let portrait = portraitMatteID {
            params["portrait_matte_id"] = portrait
        }
        return params
    }

    // Python: set_slideshow_status(duration, type, category)
    static func setSlideshowStatus(durationMinutes: Int, shuffle: Bool, categoryID: String = "MY-C0002") -> [String: Any] {
        [
            "request": "set_slideshow_status",
            "value": durationMinutes > 0 ? String(durationMinutes) : "off",
            "category_id": categoryID,
            "type": shuffle ? "shuffleslideshow" : "slideshow"
        ]
    }

    // Python: get_slideshow_status()
    static func getSlideshowStatus() -> [String: Any] {
        ["request": "get_slideshow_status"]
    }

    // Python: get_auto_rotation_status()
    static func getAutoRotationStatus() -> [String: Any] {
        ["request": "get_auto_rotation_status"]
    }

    // Python: get_artmode_settings()
    static func getArtmodeSettings() -> [String: Any] {
        ["request": "get_artmode_settings"]
    }

    // Python: change_favorite(content_id, status)
    static func changeFavorite(contentID: String, on: Bool) -> [String: Any] {
        [
            "request": "change_favorite",
            "content_id": contentID,
            "status": on ? "on" : "off"
        ]
    }

    // Python: get_matte_list()
    static func getMatteList() -> [String: Any] {
        ["request": "get_matte_list"]
    }

    // Python: get_photo_filter_list()
    static func getPhotoFilterList() -> [String: Any] {
        ["request": "get_photo_filter_list"]
    }

    // MARK: - Thumbnail Command
    //
    // Python: get_thumbnail_list(content_id_list)
    // NOTE: conn_info.id gets its OWN uuid (not the outer request uuid).
    // Python calls get_uuid() which generates a new one each time.
    //
    static func getThumbnailList(contentIDs: [String]) -> (params: [String: Any], connUUID: String) {
        let connUUID = generateUUID()
        let contentIDList = contentIDs.map { ["content_id": $0] }
        let params: [String: Any] = [
            "request": "get_thumbnail_list",
            "content_id_list": contentIDList,
            "conn_info": [
                "d2d_mode": "socket",
                "connection_id": randomConnectionID(),
                "id": connUUID
            ]
        ]
        return (params, connUUID)
    }

    // MARK: - Upload Command (send_image)
    //
    // Python: upload() — NOTE: id, request_id, and conn_info.id must ALL be the same UUID.
    //
    // Python source (art.py lines 445-462):
    //   data = self._send_art_request({
    //       "request": "send_image",
    //       "file_type": file_type,
    //       "request_id": self.get_uuid(),
    //       "id": self.art_uuid,             ← same as request_id (get_uuid sets art_uuid)
    //       "conn_info": {
    //           "d2d_mode": "socket",
    //           "connection_id": random...,
    //           "id": self.art_uuid,         ← same again
    //       },
    //       "image_date": date,
    //       "matte_id": matte,
    //       "portrait_matte_id": portrait_matte,
    //       "file_size": file_size,
    //   }, wait_for_event="ready_to_use")
    //
    static func sendImage(
        fileType: String,
        fileSize: Int,
        matteID: String,
        portraitMatteID: String,
        imageDate: String? = nil
    ) -> (params: [String: Any], uploadUUID: String) {
        let uploadUUID = generateUUID()
        let date = imageDate ?? Self.currentImageDate()

        // Python: if file_type == "jpeg": file_type = "jpg"
        let tvFileType = fileType.lowercased() == "jpeg" ? "jpg" : fileType.lowercased()

        let params: [String: Any] = [
            "request": "send_image",
            "file_type": tvFileType,
            "file_size": fileSize,
            "image_date": date,
            "matte_id": matteID,
            "portrait_matte_id": portraitMatteID,
            "id": uploadUUID,
            "request_id": uploadUUID,
            "conn_info": [
                "d2d_mode": "socket",
                "connection_id": randomConnectionID(),
                "id": uploadUUID    // Must be same as outer id
            ]
        ]
        return (params, uploadUUID)
    }

    // MARK: - Upload Header
    //
    // Python: header = json.dumps({num, total, fileLength, fileName, fileType, secKey, version})
    // Sent over the TCP data socket before the image bytes.
    //
    static func uploadHeader(fileSize: Int, fileType: String, secKey: String) -> [String: Any] {
        let tvFileType = fileType.lowercased() == "jpeg" ? "jpg" : fileType.lowercased()
        return [
            "num": 0,
            "total": 1,
            "fileLength": fileSize,
            "fileName": "dummy",
            "fileType": tvFileType,
            "secKey": secKey,
            "version": "0.0.1"
        ]
    }

    // MARK: - URL Builders
    //
    // Python: SamsungTVWSBaseConnection._format_websocket_url()
    //   ws://{host}:{port}/api/v2/channels/{app}?name={name}           (port 8001)
    //   wss://{host}:{port}/api/v2/channels/{app}?name={name}&token={token}  (port 8002)
    //
    // Name is base64-encoded. Python: helper.serialize_string(self.name)
    //

    nonisolated static let remoteControlEndpoint = "samsung.remote.control"
    nonisolated static let artAppEndpoint = "com.samsung.art-app"

    nonisolated static func websocketURL(
        host: String,
        port: Int,
        endpoint: String,
        name: String = "LightFrame",
        token: String? = nil
    ) -> URL? {
        let isSSL = port == 8002
        let b64Name = Data(name.utf8).base64EncodedString()

        var urlString: String
        if isSSL {
            urlString = "wss://\(host):\(port)/api/v2/channels/\(endpoint)?name=\(b64Name)"
            if let token = token {
                urlString += "&token=\(token)"
            }
        } else {
            urlString = "ws://\(host):\(port)/api/v2/channels/\(endpoint)?name=\(b64Name)"
        }
        return URL(string: urlString)
    }

    nonisolated static func remoteControlURL(host: String, port: Int = 8002, token: String? = nil) -> URL? {
        websocketURL(host: host, port: port, endpoint: remoteControlEndpoint, token: token)
    }

    nonisolated static func artChannelURL(host: String, port: Int = 8002, token: String? = nil) -> URL? {
        websocketURL(host: host, port: port, endpoint: artAppEndpoint, token: token)
    }

    // MARK: - Helpers

    // Python: datetime.now().strftime("%Y:%m:%d %H:%M:%S")
    private nonisolated static func currentImageDate() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return df.string(from: Date())
    }
}
