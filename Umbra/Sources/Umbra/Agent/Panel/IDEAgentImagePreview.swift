import AppKit
import SwiftUI

/// The zoom arithmetic of the image preview, pure so it is tested without a view.
enum IDEAgentImageZoom {
    static let range: ClosedRange<CGFloat> = 0.25...8
    static let step: CGFloat = 1.25

    static func clamp(_ scale: CGFloat) -> CGFloat { min(max(scale, range.lowerBound), range.upperBound) }

    /// The scale that shows the whole image in `viewport`, never above 1 (a small image is not blown up).
    static func fit(image: CGSize, in viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return clamp(min(1, viewport.width / image.width, viewport.height / image.height))
    }

    static func zoomIn(_ scale: CGFloat) -> CGFloat { clamp(scale * step) }
    static func zoomOut(_ scale: CGFloat) -> CGFloat { clamp(scale / step) }
}

/// An attached image at full size in a sheet: pinch (or ⌘+ / ⌘−) to zoom, drag to pan, double-click or ⌘0 to fit,
/// Esc or Done to close.
struct IDEAgentImagePreview: View {
    let image: IDEAttachedImage
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var didFit = false

    private var nsImage: NSImage? { NSImage(data: image.data) }
    private var shownScale: CGFloat { IDEAgentImageZoom.clamp(scale * gestureScale) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                ZStack {
                    IDEAppearance.ColorToken.editor
                    if let nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: image.pixelSize.width * shownScale, height: image.pixelSize.height * shownScale)
                            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                            .accessibilityLabel("Attached image, \(Int(image.pixelSize.width)) by \(Int(image.pixelSize.height)) pixels")
                    } else {
                        Text("This image can't be shown.")
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .onChanged { gestureScale = $0.magnification }
                    .onEnded { value in
                        scale = IDEAgentImageZoom.clamp(scale * value.magnification)
                        gestureScale = 1
                    })
                .simultaneousGesture(DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                        dragOffset = .zero
                    })
                .onTapGesture(count: 2, perform: fit)
                .onAppear {
                    viewport = proxy.size
                    if !didFit { didFit = true; fit() }
                }
                .onChange(of: proxy.size) { _, size in viewport = size }
            }
        }
        .frame(minWidth: 480, idealWidth: 760, minHeight: 360, idealHeight: 560)
        .background(IDEAppearance.ColorToken.card)
    }

    private var toolbar: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer()
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { scale = IDEAgentImageZoom.zoomOut(scale) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= IDEAgentImageZoom.range.lowerBound)
            Text("\(Int((shownScale * 100).rounded()))%")
                .font(IDEAppearance.Typography.caption.monospacedDigit())
                .frame(minWidth: 44)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { scale = IDEAgentImageZoom.zoomIn(scale) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("=", modifiers: .command)
                .disabled(scale >= IDEAgentImageZoom.range.upperBound)
            Button("Fit", action: fit)
                .keyboardShortcut("0", modifiers: .command)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(IDEAppearance.Spacing.sm)
    }

    private func fit() {
        scale = IDEAgentImageZoom.fit(image: image.pixelSize, in: viewport)
        offset = .zero
    }
}
