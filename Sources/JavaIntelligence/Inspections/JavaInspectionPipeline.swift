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
            // Error isolation while typing: the tree has a syntax error somewhere, so the
            // full semantic context stays gated — but the import list only reflects
            // well-formed declarations, and allowlisted rules only read well-formed nodes,
            // so both stay trustworthy and are still reported. Findings that touch the
            // broken regions are dropped: they would describe half-written text.
            let tolerant = JavaInspectionContext(
                toleratingErrors: text, tree: tree, url: url, index: index,
                thresholds: thresholds, languageLevel: languageLevel)
            var isolated: [JavaInspection] = []
            if enabled.contains(.unusedImport) {
                isolated.append(contentsOf: JavaUnusedImportInspection.inspect(source: text, tree: tree, toleratingErrors: true))
            }
            if enabled.contains(.duplicateImport) {
                isolated.append(contentsOf: JavaDuplicateImportInspection.inspect(source: text, tree: tree))
            }
            let allowed = enabled.intersection(Self.brokenTreeRules)
            if allowed.contains(.classFileNameMismatch) {
                isolated.append(contentsOf: JavaClassFileNameInspection.inspect(context: tolerant))
            }
            isolated.append(contentsOf: JavaInspectionRunner.run(context: tolerant, enabled: allowed))
            return isolated.filter { !tolerant.touchesError($0) }
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

    /// Rules allowed on broken trees. The broken-tree screen over the parity corpus owns
    /// this list: a rule joins only with zero invented findings across the corpus, because
    /// tables built over a broken tree silently omit the broken regions.
    ///
    /// Screened over the parity corpus (`java-diagnostics survival`, `foo(` injected into
    /// the first method, 4,870 baseline findings outside the edited member): every node
    /// rule survives with zero inventions except the exclusions below, so the set derives
    /// from the registry minus those exclusions. Data-flow, typed, project, unresolved
    /// and `missing-override` rules never reach the node runner on this path, so they stay
    /// strict-only by construction. (Kept as a closure: a key-path `map` static
    /// initializer crashes this toolchain's SILGen on the `any JavaNodeInspection`
    /// existential.)
    static let brokenTreeRules: Set<JavaInspectionRule> = {
        var rules = Set(JavaInspectionRegistry.nodeInspections.map { $0.rule })
        rules.subtract(brokenTreeExclusions)
        rules.insert(.classFileNameMismatch)
        return rules
    }()

    /// Node rules barred from broken trees. `class-length` embeds its count in the
    /// message, so every line insertion reinvents it (11 inventions); `missing-serial`
    /// concluded absence from a table the error recovery had silently truncated
    /// (false `serialVersionUID` fire on `java.lang.Number`, which declares one); the
    /// `unused-*` rules read use-completeness the same way and stay out with it. A new
    /// absence-style or count-message rule joins this list, not the allowlist, until the
    /// survival screen clears it.
    static let brokenTreeExclusions: Set<JavaInspectionRule> = [
        .classLength,
        .missingSerialVersionUID,
        .unusedPrivateMember,
        .unusedLocalVariable,
        .unusedParameter,
    ]

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
