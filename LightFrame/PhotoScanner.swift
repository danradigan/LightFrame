import Foundation
import AppKit

// MARK: - PhotoScanner
// Scans a folder on disk and builds an array of Photo objects.
// Reads EXIF matte tags from each file and cross-references with
// the sync store to determine which photos are already on the TV.
class PhotoScanner {

    // Supported image file extensions
    static let supportedExtensions = ["jpg", "jpeg", "png"]

    // MARK: - Scan Folder
    /// Scans a folder and returns an array of Photo objects, one per image file.
    /// This is async because reading EXIF from many files can take a moment.
    /// - Parameters:
    ///   - folderURL: The folder to scan
    ///   - existingPhotos: Previously scanned photos — used to preserve UUIDs and TV state
    ///   - syncStore: Used to check which photos have been uploaded to the TV
    static func scan(
        folderURL: URL,
        existingPhotos: [Photo] = [],
        syncStore: SyncStore
    ) async -> [Photo] {

        // Build a lookup of existing photos by filename so we can preserve their IDs
        let existingByFilename = Dictionary(
            uniqueKeysWithValues: existingPhotos.map { ($0.filename, $0) }
        )

        // Ask the file system for all files in the folder
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("❌ PhotoScanner: Could not read folder \(folderURL.path)")
            return []
        }

        // Filter to only supported image types and sort alphabetically by filename
        let imageURLs = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        print("📂 PhotoScanner: Found \(imageURLs.count) images in \(folderURL.lastPathComponent)")

        // Build Photo objects for each file
        // We use a task group so we can read EXIF from multiple files concurrently
        return await withTaskGroup(of: Photo?.self) { group in
            for url in imageURLs {
                group.addTask {
                    await Self.buildPhoto(
                        url: url,
                        existing: existingByFilename[url.lastPathComponent],
                        syncStore: syncStore
                    )
                }
            }

            // Collect results, filter out any nils, sort by filename
            var photos: [Photo] = []
            for await photo in group {
                if let photo = photo {
                    photos.append(photo)
                }
            }
            return photos.sorted { $0.filename < $1.filename }
        }
    }

    // MARK: - Build Single Photo
    /// Creates a Photo object for a single file.
    /// Reuses existing UUID if we've seen this file before.
    private static func buildPhoto(
        url: URL,
        existing: Photo?,
        syncStore: SyncStore
    ) async -> Photo? {
        // Read the matte from EXIF — this is the slow part
        let matte = EXIFManager.readMatte(from: url)

        // Look up whether this photo is already on the TV
        let contentID = syncStore.contentID(for: url.lastPathComponent)
        let isOnTV = contentID != nil

        return Photo(
            id: existing?.id ?? UUID(),    // Reuse existing ID if we have it
            url: url,
            matte: matte,
            tvContentID: contentID,
            isOnTV: isOnTV
        )
    }

    // MARK: - Thumbnail
    /// Generates a thumbnail NSImage for a photo at a given size.
    /// Uses ImageIO for efficiency — doesn't load the full resolution image.
    static func thumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            // Tell ImageIO the maximum dimension we want
            kCGImageSourceThumbnailMaxPixelSize: size * 2, // 2x for retina
            // Create the thumbnail even if one isn't embedded in the file
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Respect the image's EXIF orientation
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
