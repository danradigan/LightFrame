import Foundation
import AppKit

final class PhotoScanner: Sendable {

    static let supportedExtensions = ["jpg", "jpeg", "png"]

    static func scan(
        folderURL: URL,
        existingPhotos: [Photo] = [],
        syncStore: SyncStore
    ) async -> [Photo] {

        let existingByFilename = Dictionary(
            uniqueKeysWithValues: existingPhotos.map { ($0.filename, $0) }
        )

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("❌ PhotoScanner: Could not read folder \(folderURL.path)")
            return []
        }

        let imageURLs = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        print("📂 PhotoScanner: Found \(imageURLs.count) images in \(folderURL.lastPathComponent)")

        // Pre-load raw file data while security scope is open
        var fileDataMap: [URL: Data] = [:]
        for url in imageURLs {
            if let data = try? Data(contentsOf: url) {
                fileDataMap[url] = data
            }
        }

        print("📂 PhotoScanner: Pre-loaded \(fileDataMap.count) files")

        return await withTaskGroup(of: Photo?.self) { group in
            for url in imageURLs {
                let data = fileDataMap[url]
                let existing = existingByFilename[url.lastPathComponent]
                let contentID = syncStore.contentID(for: url.lastPathComponent)

                group.addTask {
                    let matte = data.flatMap { EXIFManager.readMatteFromData($0) }
                    return Photo(
                        id: existing?.id ?? UUID(),
                        url: url,
                        matte: matte,
                        tvContentID: contentID,
                        isOnTV: contentID != nil,
                        thumbnailData: data
                    )
                }
            }

            var photos: [Photo] = []
            for await photo in group {
                if let photo = photo { photos.append(photo) }
            }
            return photos.sorted { $0.filename < $1.filename }
        }
    }

    // MARK: - Generate Thumbnail
    // Uses actual CGImage pixel dimensions so aspect ratio is always correct
    static func thumbnailImage(from data: Data, size: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Int(size * 2),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        // Use actual pixel dimensions — critical for correct aspect ratio
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        return NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
    }

    static func thumbnail(from data: Data, size: CGFloat) -> NSImage? {
        thumbnailImage(from: data, size: size)
    }

    static func thumbnail(for url: URL, size: CGFloat) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return thumbnailImage(from: data, size: size)
    }
}
