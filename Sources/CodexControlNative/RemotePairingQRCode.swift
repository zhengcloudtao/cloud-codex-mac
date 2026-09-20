import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum RemotePairingQRCode {
    static let scheme = "cloudcodex"
    static let host = "pair"

    static func payload(code: String) -> String? {
        guard code.count == 8, code.allSatisfy(\.isNumber) else { return nil }
        return "\(scheme)://\(host)?v=1&code=\(code)"
    }

    static func expirationDate(_ rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: rawValue) { return value }
        return ISO8601DateFormatter().date(from: rawValue)
    }

    static func image(payload: String, scale: CGFloat = 10) -> NSImage? {
        guard !payload.isEmpty, scale > 0 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
