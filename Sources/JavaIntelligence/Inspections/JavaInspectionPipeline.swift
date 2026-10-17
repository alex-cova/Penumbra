import EditorIntelligence
import Foundation

/// The one path from a file's text to its inspection findings. The on-the-fly service and the
/// batch runner both go through it, so a rule behaves the same in the editor and in Inspect Code.
enum JavaInspectionPipeline {
    /// Findings for one parsed file, before suppression and the profile's severities.
    /// `projectFindings` are the project-wide rules' findings for this exact text, if known.
    static func inspect(
        text: String,
        url: URL,
        tree: JavaSyntaxTree,
        index: JavaIndex,
        enabled: Set<JavaInspectionRule>,
        thresholds: JavaInspectionThresholds,
        projectFindings: [JavaInspection] = [],
        languageLevel: Int? = nil
    ) async -> [JavaInspection] {
        guard let context = JavaInspectionContext(
            source: text, tree: tree, url: url, index: index, thresholds: thresholds, languageLevel: languageLevel
        ) else {
            // Error isolation while typing: the tree has a syntax error somewhere, which
            // fails the semantic context, but the import list only reflects well-formed
            // declarations — so unused and duplicate imports stay trustworthy and are still
            // reported. Everything semantic stays gated on a clean tree.
            var isolated: [JavaInspection] = []
            if enabled.contains(.unusedImport) {
                isolated.append(contentsOf: JavaUnusedImportInspection.inspect(source: text, tree: tree, toleratingErrors: true))
            }
            if enabled.contains(.duplicateImport) {
                isolated.append(contentsOf: JavaDuplicateImportInspection.inspect(source: text, tree: tree))
            }
            return isolated
        }
        var found: [JavaInspection] = []
        // A superseded pass stops between stages instead of racing the fresh one to the
        // cache; `runAnalysis` also refuses to publish a cancelled pass.
        if Task.isCancelled { return found }
        if enabled.contains(.unusedImport) {
            found.append(contentsOf: JavaUnusedImportInspection.inspect(source: text, tree: tree))
        }
        if enabled.contains(.duplicateImport) {
            found.append(contentsOf: JavaDuplicateImportInspection.inspect(source: text, tree: tree))
        }
        if enabled.contains(.unresolvedImport) {
            found.append(contentsOf: await JavaUnresolvedImportInspection.inspect(context: context, index: index))
        }
        if enabled.contains(.missingOverride) {
            found.append(contentsOf: await JavaMissingOverrideInspection.inspect(source: text, url: url, index: index, tree: tree))
        }
        if enabled.contains(.unresolvedType) {
            found.append(contentsOf: await JavaUnresolvedTypeInspection.inspect(source: text, url: url, index: index, walker: context.walker))
        }
        if enabled.contains(.classFileNameMismatch) {
            found.append(contentsOf: JavaClassFileNameInspection.inspect(context: context))
        }
        found.append(contentsOf: JavaInspectionRunner.run(context: context, enabled: enabled))
        if Task.isCancelled { return found }
        found.append(contentsOf: JavaInspectionRunner.runFlow(context: context, enabled: enabled))
        found.append(contentsOf: projectFindings.filter { inspection in
            JavaInspectionRule(code: inspection.id).map(enabled.contains) == true
        })
        if Task.isCancelled { return found }
        found.append(contentsOf: await JavaInspectionRunner.runTyped(context: context, enabled: enabled))
        return found
    }

    /// What the user sees and what stays quiet.
    struct Outcome {
        var visible: [JavaInspection]
        /// Findings whose severity is "No highlighting (fix available)": not listed or drawn, but
        /// their fixes are offered on ⌥↩.
        var quiet: [JavaInspection]
    }

    /// Drops what `@SuppressWarnings` / `//noinspection` silences, applies the profile's severities
    /// for `file` and splits off the quiet findings.
    static func finalize(
        _ inspections: [JavaInspection],
        text: String,
        profile: JavaInspectionProfile,
        file: JavaInspectionFileContext?
    ) -> Outcome {
        var result = suppressionFiltered(inspections, text: text)
        if !profile.severities.isEmpty || !profile.scopedOverrides.isEmpty {
            result = result.map { inspection in
                guard let rule = JavaInspectionRule(code: inspection.id) else { return inspection }
                let resolution = profile.resolution(of: rule, in: file)
                return resolution.isSeverityExplicit ? inspection.withSeverity(resolution.severity) : inspection
            }
        }
        guard result.contains(where: { $0.severity == .noHighlighting }) else { return Outcome(visible: result, quiet: []) }
        return Outcome(
            visible: result.filter { $0.severity != .noHighlighting },
            quiet: result.filter { $0.severity == .noHighlighting }
        )
    }

    /// Drops what an `@SuppressWarnings` or `//noinspection` in the file silences.
    static func suppressionFiltered(_ inspections: [JavaInspection], text: String) -> [JavaInspection] {
        guard !inspections.isEmpty, text.contains("SuppressWarnings") || text.contains("noinspection"),
              let tree = JavaSyntaxParser().parse(text) else { return inspections }
        let ns = text as NSString
        return inspections.filter { inspection in
            let location = min(max(0, inspection.range.start.utf16Offset), ns.length)
            let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: location, in: text)
            return !JavaSuppression.isSuppressed(code: inspection.id, atByteOffset: byteOffset, tree: tree)
        }
    }
}
