import AppKit
import CoreGraphics
import Foundation

/// `Pointer --selftest-stream` exercises the request build + SSE parse path
/// against whatever endpoint `POINTER_ANTHROPIC_BASE_URL` /
/// `POINTER_OPENAI_BASE_URL` points at. Pointing those at a local fake server
/// verifies streaming without a live API key or Screen Recording permission.
enum SelfTest {

    static func runStreamTest() -> Never {
        let provider: Provider =
            (ProcessInfo.processInfo.environment["POINTER_SELFTEST_PROVIDER"] == "openai")
            ? .openai : .anthropic

        var settings = Settings()
        settings.provider = provider

        FileHandle.standardError.write(Data("""
            selftest: provider=\(provider.rawValue) \
            endpoint=\(Providers.baseURL(for: provider))\n
            """.utf8))

        guard let png = tinyPNG() else {
            print("FAIL: could not build a test image")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var collected = ""
        var sawThinking = false
        var failure: String?

        Task {
            let client = Providers.provider(for: settings)
            do {
                for try await event in client.stream(
                    prompt: "Explain this code.",
                    imagePNG: png,
                    settings: settings
                ) {
                    switch event {
                    case .thinkingStarted:
                        sawThinking = true
                    case .textDelta(let text):
                        collected += text
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            print("FAIL: timed out after 30s")
            exit(1)
        }

        if let failure {
            print("FAIL: \(failure)")
            exit(1)
        }

        print("thinkingSignal=\(sawThinking)")
        print("text=\(collected)")
        if collected.isEmpty {
            print("FAIL: stream produced no text")
            exit(1)
        }
        print("OK")
        exit(0)
    }

    /// Minimal valid PNG so the request body is well-formed.
    private static func tinyPNG() -> Data? {
        let width = 8
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return ScreenCapture.pngData(from: image)
    }
}
