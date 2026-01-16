import Foundation
import ImageIO

public struct EXIFReader: Sendable {
    public init() {}

    public func extractDateTimeOriginal(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        // Prefer EXIF DateTimeOriginal.
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let date = parseExifDate(dateStr) {
            return date
        }

        // Fallback: TIFF DateTime (often present when EXIF isn't).
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let dateStr = tiff[kCGImagePropertyTIFFDateTime as String] as? String,
           let date = parseExifDate(dateStr) {
            return date
        }

        return nil
    }

    private func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

