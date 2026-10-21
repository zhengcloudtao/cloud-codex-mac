import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Only called for typed image inputs / imageGeneration savedPath or result from the
/// authorized turn. Never follows Markdown paths, tool arguments or remote URLs.
enum RemoteHistoryImageEncoder {
    static let maxImageBytes = 512 * 1024
    static let maxImages = 8

    static func encode(_ value: String, name: String) -> RemoteHistoryImage? {
        let source: CGImageSource?
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if value.hasPrefix("data:image/"), value.utf8.count <= 44 * 1024 * 1024,
           let comma = value.firstIndex(of: ","), value[..<comma].hasSuffix(";base64"),
           let bytes = Data(base64Encoded: String(value[value.index(after: comma)...])) {
            source = CGImageSourceCreateWithData(bytes as CFData, options)
        } else if value.hasPrefix("/"),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: value),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 32 * 1024 * 1024 {
            source = CGImageSourceCreateWithURL(URL(fileURLWithPath: value) as CFURL, options)
        } else { return nil }
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              Double(width) * Double(height) <= 100_000_000 else { return nil }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? true
        for size in [1600, 1200, 800, 480, 320] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { return nil }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if bytes.length <= maxImageBytes {
                return RemoteHistoryImage(name: name, mimeType: "image/png", data: (bytes as Data).base64EncodedString())
            }
            // Opaque photos retain more detail as JPEG; transparent artwork
            // stays PNG so the preview does not lose its background transparency.
            if !hasAlpha {
                let jpeg = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                    if CGImageDestinationFinalize(destination), jpeg.length <= maxImageBytes {
                        return RemoteHistoryImage(name: name, mimeType: "image/jpeg", data: (jpeg as Data).base64EncodedString())
                    }
                }
            }
        }
        return nil
    }
}
