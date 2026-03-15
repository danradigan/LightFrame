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

        return await withTaskGroup(of: Photo?.self) { group in
            for url in imageURLs {
                let existing = existingByFilename[url.lastPathComponent]
                let contentID = syncStore.contentID(for: url.lastPathComponent)

                group.addTask {
                    // Read full data only temporarily for EXIF + thumbnail generation
                    guard let fullData = try? Data(contentsOf: url) else { return nil }

                    let matte = EXIFManager.readMatteFromData(fullData)

                    // Generate a 600px thumbnail and compress as JPEG (~20-40KB)
                    let thumbData = Self.generateThumbnailData(from: fullData, maxSize: 600)

                    // Read pixel dimensions from image source
                    var imgWidth: Int? = nil
                    var imgHeight: Int? = nil
                    if let source = CGImageSourceCreateWithData(fullData as CFData, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                        imgWidth = props[kCGImagePropertyPixelWidth as String] as? Int
                        imgHeight = props[kCGImagePropertyPixelHeight as String] as? Int
                    }

                    return Photo(
                        id: existing?.id ?? UUID(),
                        url: url,
                        matte: matte,
                        tvContentID: contentID,
                        isOnTV: contentID != nil,
                        thumbnailData: thumbData,
                        width: imgWidth,
                        height: imgHeight
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

    // MARK: - Generate Thumbnail Data
    // Creates a compressed JPEG thumbnail at the given max pixel size.
    // Returns ~20-40KB instead of the original 1-3MB.
    nonisolated static func generateThumbnailData(from data: Data, maxSize: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSize),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
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
