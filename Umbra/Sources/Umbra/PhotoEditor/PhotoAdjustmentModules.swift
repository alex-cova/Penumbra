import SwiftUI

/// The three data-driven tone/color modules (BASIC, DETAIL, EFFECTS). Each is a `PhotoInspectorModule`
/// over a list of `PhotoParameterRow` leaves, plus the RAW noise-reduction band folded into DETAIL
/// when the source is a RAW file.
struct PhotoAdjustmentModuleView: View {
    @Bindable var session: PhotoEditorSession
    let module: AdjustmentParameter.Module

    @AppStorage private var isExpanded: Bool

    init(session: PhotoEditorSession, module: AdjustmentParameter.Module) {
        self.session = session
        self.module = module
        _isExpanded = AppStorage(
            wrappedValue: module == .basic,
            "photoEditor.module.\(module.rawValue)"
        )
    }

    var body: some View {
        PhotoInspectorModule(
            title: module.displayName,
            isExpanded: $isExpanded,
            trailing: { PhotoModuleResetButton(session: session, module: module) }
        ) {
            ForEach(module.parameters) { parameter in
                PhotoParameterRow(session: session, parameter: parameter)
            }
            if module == .detail, session.isRAW {
                Divider().overlay(PhotoStudio.Photo.hairline)
                ForEach(RAWParameter.detailBand) { parameter in
                    PhotoRAWParameterRow(session: session, parameter: parameter)
                }
            }
        }
    }
}

/// Leaf that reads exactly one parameter value. Keeping the `session.adjustments` read down here
/// means an unrelated slider drag re-evaluates ten of these cheap rows instead of the whole module,
/// and SwiftUI's diff stops at the unchanged `PhotoAdjustmentSlider` value.
struct PhotoParameterRow: View {
    @Bindable var session: PhotoEditorSession
    let parameter: AdjustmentParameter

    var body: some View {
        PhotoAdjustmentSlider(
            value: session.adjustments[keyPath: parameter.keyPath],
            parameterName: parameter.displayName,
            lowerBound: parameter.range.lowerBound,
            upperBound: parameter.range.upperBound,
            detent: parameter.detent,
            gradient: parameter.gradient,
            onChanged: { newValue in
                session.mutate { $0[keyPath: parameter.keyPath] = newValue }
            },
            onEnded: { session.commit() }
        )
    }
}

/// Leaf that reads exactly one CIRAWFilter decode control.
struct PhotoRAWParameterRow: View {
    @Bindable var session: PhotoEditorSession
    let parameter: RAWParameter

    var body: some View {
        PhotoAdjustmentSlider(
            value: session.adjustments.raw[keyPath: parameter.keyPath],
            parameterName: parameter.displayName,
            lowerBound: parameter.range.lowerBound,
            upperBound: parameter.range.upperBound,
            detent: parameter.detent,
            gradient: parameter.gradient,
            onChanged: { newValue in
                session.mutate { $0.raw[keyPath: parameter.keyPath] = newValue }
            },
            onEnded: { session.commit() }
        )
    }
}

/// Isolated module-header reset so `module.isIdentity(in:)` does not pull `session.adjustments`
/// into the module body itself.
struct PhotoModuleResetButton: View {
    @Bindable var session: PhotoEditorSession
    let module: AdjustmentParameter.Module

    var body: some View {
        PhotoInspectorResetButton(isEnabled: !module.isIdentity(in: session.adjustments)) {
            session.mutate { module.reset(&$0) }
            session.commit()
        }
    }
}
