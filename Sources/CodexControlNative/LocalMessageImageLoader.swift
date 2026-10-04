import Foundation
import ImageIO

/// Decode a display-sized image away from the main actor. The conversation
/// keeps its original URL for opening/copying; only its inline preview is small.
actor LocalMessageImageLoader {
    static let shared = LocalMessageImageLoader()

    private final class Entry: NSObject {
        let modified: Date?
        let fileSize: Int?
        let image: CGImage

        init(modified: Date?, fileSize: Int?, image: CGImage) {
            self.modified = modified
            self.fileSize = fileSize
            self.image = image
        }
    }

    private let cache = NSCache<NSURL, Entry>()
    private(set) var decodeCount = 0

    init() {
        cache.countLimit = 32
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func thumbnail(at url: URL) -> CGImage? {
        // URL.resourceValues can retain stale metadata on a reused URL. Read
        // fresh attributes so replacing/deleting an original expires the cache.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            cache.removeObject(forKey: url as NSURL)
            return nil
        }
        let modified = values[.modificationDate] as? Date
        let fileSize = (values[.size] as? NSNumber)?.intValue
        if let entry = cache.object(forKey: url as NSURL),
           entry.modified == modified, entry.fileSize == fileSize {
            return entry.image
        }
        cache.removeObject(forKey: url as NSURL)
        decodeCount += 1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1040,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let entry = Entry(modified: modified, fileSize: fileSize, image: image)
        cache.setObject(entry, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}
