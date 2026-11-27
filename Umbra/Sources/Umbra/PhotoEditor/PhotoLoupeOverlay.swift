import SwiftUI

/// Magnified patch of the rendered preview under the cursor, with hex / RGB / HSL readouts. The
/// sample comes from the on-screen preview proxy, not the full-resolution source.
struct PhotoLoupeOverlay: View {
    let preview: CGImage
    let pixel: PhotoSampledPixel
    var onCopy: (String) -> Void

    private let diameter: CGFloat = 120
    private let magnification: CGFloat = 11

    private var swatch: Color {
        Color(
            red: Double(pixel.red) / 255,
            green: Double(pixel.green) / 255,
            blue: Double(pixel.blue) / 255
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            loupe
            readout
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: PhotoStudio.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: PhotoStudio.Radius.sm)
                .strokeBorder(.white.opacity(0.15))
        }
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Colour sample \(pixel.hex), RGB \(pixel.rgbText)")
    }

    private var loupe: some View {
        Image(decorative: preview, scale: 1, orientation: .up)
            .interpolation(.none)
            .resizable()
            .frame(
                width: CGFloat(preview.width) * magnification,
                height: CGFloat(preview.height) * magnification
            )
            .offset(
                x: -(pixel.location.x + 0.5) * magnification + diameter / 2,
                y: -(pixel.location.y + 0.5) * magnification + diameter / 2
            )
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay {
                Rectangle()
                    .strokeBorder(.white, lineWidth: 1)
                    .frame(width: magnification, height: magnification)
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.6)) }
            .accessibilityHidden(true)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                onCopy(pixel.hex)
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(swatch)
                        .frame(width: 14, height: 14)
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.3)) }
                    Text(pixel.hex)
                        .font(.caption.monospaced())
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Copy hex")

            Text("RGB  \(pixel.rgbText)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("HSL  \(pixel.hslText)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
