import AppKit
import XCTest
@testable import Runestone

@MainActor
struct HostedMetalTextView {
    let window: NSWindow
    let textView: TextView

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

extension XCTestCase {
    @MainActor
    func makeCapturingMetalTextView(
        text: String,
        size: CGSize = CGSize(width: 640, height: 360),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HostedMetalTextView {
        TextView.allowsMetalDrawableCapture = true
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        window.contentView = container
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
        pumpMainRunLoop()
        XCTAssertTrue(textView.isMetalRenderingActive, file: file, line: line)
        return HostedMetalTextView(window: window, textView: textView)
    }

    @MainActor
    func pumpMainRunLoop(for duration: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    func paintedPixelCount(in image: NSBitmapImageRep) -> Int {
        guard let data = image.bitmapData else {
            return 0
        }
        var count = 0
        for y in 0..<image.pixelsHigh {
            let row = data.advanced(by: y * image.bytesPerRow)
            for x in 0..<image.pixelsWide {
                let pixel = row.advanced(by: x * image.samplesPerPixel)
                if image.hasAlpha {
                    if pixel[image.samplesPerPixel - 1] != 0 {
                        count += 1
                    }
                } else if (0..<min(image.samplesPerPixel, 3)).contains(where: { pixel[$0] != 0 }) {
                    count += 1
                }
            }
        }
        return count
    }

    func differingPixelCount(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        tolerance: UInt8 = 2
    ) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide,
              lhs.pixelsHigh == rhs.pixelsHigh,
              let left = lhs.bitmapData,
              let right = rhs.bitmapData else {
            return 0
        }
        let channels = min(lhs.samplesPerPixel, rhs.samplesPerPixel)
        var count = 0
        for y in 0..<lhs.pixelsHigh {
            let leftRow = left.advanced(by: y * lhs.bytesPerRow)
            let rightRow = right.advanced(by: y * rhs.bytesPerRow)
            for x in 0..<lhs.pixelsWide {
                let leftPixel = leftRow.advanced(by: x * lhs.samplesPerPixel)
                let rightPixel = rightRow.advanced(by: x * rhs.samplesPerPixel)
                let differs = (0..<channels).contains { channel in
                    abs(Int(leftPixel[channel]) - Int(rightPixel[channel])) > Int(tolerance)
                }
                if differs {
                    count += 1
                }
            }
        }
        return count
    }

    func inkPixelCount(in image: NSBitmapImageRep, tolerance: UInt8 = 8) -> Int {
        guard image.samplesPerPixel >= 3,
              let data = image.bitmapData,
              image.pixelsWide > 0,
              image.pixelsHigh > 0 else {
            return 0
        }
        let background = data.advanced(by: (image.pixelsWide - 1) * image.samplesPerPixel)
        let reference = (background[0], background[1], background[2])
        var count = 0
        for y in 0..<image.pixelsHigh {
            let row = data.advanced(by: y * image.bytesPerRow)
            for x in 0..<image.pixelsWide {
                let pixel = row.advanced(by: x * image.samplesPerPixel)
                if abs(Int(pixel[0]) - Int(reference.0)) > Int(tolerance)
                    || abs(Int(pixel[1]) - Int(reference.1)) > Int(tolerance)
                    || abs(Int(pixel[2]) - Int(reference.2)) > Int(tolerance) {
                    count += 1
                }
            }
        }
        return count
    }
}
