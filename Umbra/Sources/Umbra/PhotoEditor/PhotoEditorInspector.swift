import SwiftUI

/// Lightroom-style Develop panel: a pinned histogram + EXIF header over one scrolling stack of
/// collapsible modules. Held at a fixed studio-neutral gray (`PhotoStudio.Photo`) and forced to a dark
/// color scheme so it reads the same in system light and dark.
struct PhotoEditorInspector: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(spacing: 0) {
            PhotoHistogramView(
                histogram: session.previewHistogram,
                pixelSize: session.sourcePixelSize,
                isRAW: session.isRAW,
                exif: session.exifSummary
            )

            Rectangle()
                .fill(PhotoStudio.Photo.hairline)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    PhotoInfoPane(session: session)
                    PhotoAdjustmentModuleView(session: session, module: .basic)
                    CurvesPane(session: session)
                    SelectiveHSLPane(session: session)
                    PhotoAdjustmentModuleView(session: session, module: .detail)
                    PhotoAdjustmentModuleView(session: session, module: .effects)
                    FiltersPane(session: session)
                    CropPane(session: session)
                    RedactPane(session: session)
                    if session.isRAW {
                        RAWPane(session: session)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .background(PhotoStudio.Photo.panel)
        .environment(\.colorScheme, .dark)
        .tint(PhotoStudio.accent)
        .clipShape(.rect(cornerRadius: PhotoStudio.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: PhotoStudio.Radius.lg)
                .strokeBorder(PhotoStudio.Photo.hairline, lineWidth: 1)
        }
    }
}
