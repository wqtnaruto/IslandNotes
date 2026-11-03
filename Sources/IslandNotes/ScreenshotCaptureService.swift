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

private final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            return false
        }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if let active, active.isRunning {
            active.terminate()
        }
    }
}

struct SystemScreenshotCaptureService: ScreenshotCapturing {
    func capture(to destination: URL) async throws -> ScreenshotCaptureResult {
        let box = CancellableProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-x", "-t", "png", destination.path]

                guard box.attach(process) else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                process.terminationHandler = { process in
                    guard FileManager.default.fileExists(atPath: destination.path) else {
                        continuation.resume(returning: .cancelled)
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
        } onCancel: {
            box.cancel()
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
