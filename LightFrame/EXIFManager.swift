import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - EXIFManager
// Handles reading and writing matte metadata inside JPEG files.
// We store the matte tag in the EXIF ImageDescription field as a string
// like "flexible_warm" or "modern_black". This survives Lightroom exports
// and works with any app that reads standard EXIF data.
class EXIFManager {

    // MARK: - Read Matte from JPEG
    /// Reads the matte configuration from a photo's EXIF ImageDescription field.
    /// Returns nil if no matte tag is found or the file isn't readable.
    static func readMatte(from url: URL) -> Matte? {
        // Create an image source from the file URL
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // Get the metadata dictionary for the first image in the file
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              // Dig into the TIFF metadata dictionary where ImageDescription lives
              let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
              // Get the ImageDescription string, e.g. "flexible_warm"
              let description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String
        else {
            return nil
        }

        // Parse the description string into a Matte value
        return Matte.parse(description)
    }

    // MARK: - Write Matte to JPEG
    /// Writes a matte configuration into a JPEG file's EXIF ImageDescription field.
    /// This modifies the file in place. Only works with JPEG files.
    /// Returns true if successful, false if the write failed.
    @discardableResult
    static func writeMatte(_ matte: Matte, to url: URL) -> Bool {
        // Read the existing image data
        guard let imageData = try? Data(contentsOf: url) as CFData,
              // Create a mutable copy of the image source
              let source = CGImageSourceCreateWithData(imageData, nil),
              let uti = CGImageSourceGetType(source)
        else {
            print("❌ EXIFManager: Could not read image at \(url.lastPathComponent)")
            return false
        }

        // Create a mutable data destination to write the updated image into
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            uti,
            1,      // We're writing exactly one image
            nil
        )
        guard let destination = destination else {
            print("❌ EXIFManager: Could not create image destination for \(url.lastPathComponent)")
            return false
        }

        // Build the metadata dictionary with our matte string in ImageDescription
        // We write into the TIFF dictionary because ImageDescription is a TIFF tag
        let metadata: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFImageDescription as String: matte.apiToken
            ]
        ]

        // Copy the existing image with the new metadata merged in
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)

        // Finalize writes the data to disk
        let success = CGImageDestinationFinalize(destination)
        if success {
            print("✅ EXIFManager: Wrote matte '\(matte.apiToken)' to \(url.lastPathComponent)")
        } else {
            print("❌ EXIFManager: Failed to write matte to \(url.lastPathComponent)")
        }
        return success
    }

    // MARK: - Batch Read
    /// Reads matte tags from multiple files at once.
    /// Returns a dictionary mapping file URL to Matte (only includes files that have a matte tag).
    static func readMattes(from urls: [URL]) -> [URL: Matte] {
        var result: [URL: Matte] = [:]
        for url in urls {
            if let matte = readMatte(from: url) {
                result[url] = matte
            }
        }
        return result
    }
}
