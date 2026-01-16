import Foundation
import Darwin

public struct VolumeDetector: Sendable {
    public init() {}

    public func isCrossVolume(source: URL, destination: URL) -> Bool {
        // Compare device IDs (st_dev). Use destination parent directory since destination file may not exist yet.
        guard let sourceDevice = deviceId(path: source.path),
              let destinationDevice = deviceId(path: destination.deletingLastPathComponent().path) else {
            return false
        }
        return sourceDevice != destinationDevice
    }

    private func deviceId(path: String) -> dev_t? {
        var st = stat()
        if lstat(path, &st) != 0 {
            return nil
        }
        return st.st_dev
    }
}
