import SwiftUI

/// Pinned Lightroom-style histogram: overlapping R/G/B silhouettes with a luma outline over a
/// recessed well, corner clipping indicators, and two caption lines (dimensions + EXIF).
struct PhotoHistogramView: View {
    let histogram: PhotoHistogram
    let pixelSize: CGSize
    let isRAW: Bool
    let exif: PhotoExifSummary

    private let clipThreshold = 0.001

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Canvas { context, size in
                    guard !histogram.isEmpty else { return }
                    fill(context: context, size: size, bins: histogram.red, color: .red)
                    fill(context: context, size: size, bins: histogram.green, color: .green)
                    fill(context: context, size: size, bins: histogram.blue, color: .blue)
                    outline(context: context, size: size, bins: histogram.luma)
                }

                HStack {
                    clipDot(active: histogram.shadowClipped > clipThreshold, label: "Shadow clipping")
                    Spacer()
                    clipDot(active: histogram.highlightClipped > clipThreshold, label: "Highlight clipping")
                }
                .padding(4)
            }
            .frame(height: 84)
            .background(PhotoStudio.Photo.panelDeep, in: .rect(cornerRadius: PhotoStudio.Radius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: PhotoStudio.Radius.xs)
                    .strokeBorder(PhotoStudio.Photo.hairline, lineWidth: 1)
            }
            .accessibilityElement()
            .accessibilityLabel("Histogram")
            .accessibilityValue(clippingSummary)

            if !dimensionLine.isEmpty {
                Text(dimensionLine)
                    .font(PhotoStudio.Typography.caption2.monospacedDigit())
                    .foregroundStyle(PhotoStudio.Photo.label)
            }
            if !exif.line.isEmpty {
                Text(exif.line)
                    .font(PhotoStudio.Typography.caption2.monospacedDigit())
                    .foregroundStyle(PhotoStudio.Photo.label.opacity(0.85))
            }
        }
        .padding(.horizontal, PhotoStudio.Spacing.md)
        .padding(.vertical, PhotoStudio.Spacing.sm)
    }

    private var dimensionLine: String {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return isRAW ? "RAW" : "" }
        let base = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        return isRAW ? "\(base) · RAW" : base
    }

    private var clippingSummary: String {
        switch (histogram.shadowClipped > clipThreshold, histogram.highlightClipped > clipThreshold) {
        case (true, true): "Shadows and highlights clipping"
        case (true, false): "Shadows clipping"
        case (false, true): "Highlights clipping"
        case (false, false): "No clipping"
        }
    }

    private func clipDot(active: Bool, label: LocalizedStringResource) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 6))
            .foregroundStyle(active ? Color.white : PhotoStudio.Photo.track.opacity(0.5))
            .help(active ? Text(label) : Text(""))
            .accessibilityHidden(!active)
    }

    private func path(size: CGSize, bins: [Double]) -> Path {
        var path = Path()
        guard bins.count > 1 else { return path }
        let step = size.width / CGFloat(bins.count - 1)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in bins.enumerated() {
            let x = CGFloat(index) * step
            let y = size.height - CGFloat(min(1, max(0, value))) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func fill(context: GraphicsContext, size: CGSize, bins: [Double], color: Color) {
        var layer = context
        layer.blendMode = .screen
        layer.fill(path(size: size, bins: bins), with: .color(color.opacity(0.55)))
    }

    private func outline(context: GraphicsContext, size: CGSize, bins: [Double]) {
        context.stroke(
            path(size: size, bins: bins),
            with: .color(PhotoStudio.Photo.value.opacity(0.7)),
            lineWidth: 1
        )
    }
}
