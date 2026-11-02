import Foundation
import ImageIO

struct CapturedScreenshot: Equatable, Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenshotCaptureResult: Equatable, Sendable {
    case captured(CapturedScreenshot)
    case cancelled
}

enum ScreenshotCaptureError: LocalizedError {
    case launchFailed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            message
        case .invalidImage:
            L10n.string("The screenshot could not be saved")
        }
    }
}

protocol ScreenshotCapturing: Sendable {
    func capture(to destination: URL) async throws -> ScreenshotCaptureResult
}

struct SystemScreenshotCaptureService: ScreenshotCapturing {
    func capture(to destination: URL) async throws -> ScreenshotCaptureResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // Force region selection instead of inheriting the user's last
            // window/toolbar mode. Ask macOS to surface genuine capture errors.
            process.arguments = ["-i", "-s", "-x", "-d", "-t", "png", destination.path]
            process.standardError = errors
            process.terminationHandler = { process in
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    let errorText = String(
                        data: errors.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 1, errorText.isEmpty {
                        continuation.resume(returning: .cancelled)
                    } else {
                        continuation.resume(throwing: ScreenshotCaptureError.launchFailed(
                            errorText.isEmpty ? L10n.string("The screenshot could not be saved") : errorText
                        ))
                    }
                    return
                }
                guard process.terminationStatus == 0,
                      let dimensions = Self.pixelDimensions(at: destination) else {
                    continuation.resume(throwing: ScreenshotCaptureError.invalidImage)
                    return
                }
                continuation.resume(returning: .captured(CapturedScreenshot(
                    url: destination,
                    pixelWidth: dimensions.width,
                    pixelHeight: dimensions.height
                )))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ScreenshotCaptureError.launchFailed(error.localizedDescription))
            }
        }
    }

    private static func pixelDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0 else { return nil }
        return (width.intValue, height.intValue)
    }
}
