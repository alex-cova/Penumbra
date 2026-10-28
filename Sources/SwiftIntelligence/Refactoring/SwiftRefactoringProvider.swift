import EditorIntelligence
import Foundation

extension RefactoringID {
    public static let convertIfGuard = RefactoringID("swift.convertIfGuard")
    public static let moveToExtension = RefactoringID("swift.moveToExtension")
    public static let addExplicitType = RefactoringID("swift.addExplicitType")
    public static let optionalBindingShorthand = RefactoringID("swift.optionalBindingShorthand")
}

/// The native Swift refactorings. Each is a swift-syntax rewrite of the file: it needs no build and keeps
/// working while the file is half-edited elsewhere (a file with a syntax error is refused, never guessed at).
/// Semantic refactorings (extract method, add `Codable`, convert to `async`) come from SourceKit-LSP's code
/// actions instead.
public struct SwiftRefactoringProvider: RefactoringProviding {
    private let renamer: SwiftRenameProvider

    public init(index: SwiftIndex) {
        renamer = SwiftRenameProvider(index: index)
    }

    // MARK: - RefactoringProviding

    public func availableRefactorings(_ context: RefactoringContext) async -> [RefactoringDescriptor] {
        guard let text = Self.text(of: context.document) else { return [] }
        let map = SourceTextMap(text)
        let caret = map.byteOffset(utf16: context.cursor.position.utf16Offset)
        let selection = Self.selectionBytes(context.selection, map: map)
        var descriptors: [RefactoringDescriptor] = []
        if let selection, let name = SwiftIntroduceVariable.suggestedName(in: text, selection: selection),
           case .success = SwiftIntroduceVariable.edits(in: text, selection: selection, name: name) {
            descriptors.append(RefactoringDescriptor(
                id: .extractVariable, title: "Introduce Variable…", requiresSelection: true,
                parameterKeys: ["name"], suggestedParameters: ["name": name]
            ))
        }
        if SwiftInlineVariable.isAvailable(in: text, caret: caret) {
            descriptors.append(RefactoringDescriptor(id: .inlineVariable, title: "Inline Variable", requiresSelection: false))
        }
        if let subject = SwiftChangeSignature.subject(in: text, caret: caret) {
            descriptors.append(RefactoringDescriptor(
                id: .changeSignature, title: "Change Function Signature…", requiresSelection: false,
                parameterKeys: ["parameters"],
                suggestedParameters: ["parameters": SwiftSignatureChange(parameters: subject.parameters).json, "functionName": subject.name]
            ))
        }
        if let direction = SwiftConditionalConversion.available(in: text, caret: caret) {
            descriptors.append(RefactoringDescriptor(
                id: .convertIfGuard, title: direction == .ifToGuard ? "Convert to guard" : "Convert to if", requiresSelection: false
            ))
        }
        if SwiftMoveToExtension.isAvailable(in: text, caret: caret) {
            descriptors.append(RefactoringDescriptor(id: .moveToExtension, title: "Move to Extension", requiresSelection: false))
        }
        if SwiftAddExplicitType.isAvailable(in: text, caret: caret) {
            descriptors.append(RefactoringDescriptor(id: .addExplicitType, title: "Add Explicit Type", requiresSelection: false))
        }
        if SwiftSafeDelete.target(in: text, caret: caret) != nil {
            descriptors.append(RefactoringDescriptor(id: .safeDelete, title: "Safe Delete", requiresSelection: false))
        }
        let allowsShorthand = SwiftToolsVersion.allowsOptionalBindingShorthand(forFileAt: context.documentURL ?? context.document.url)
        if let direction = SwiftOptionalBindingShorthand.available(in: text, caret: caret, allowsShorthand: allowsShorthand) {
            descriptors.append(RefactoringDescriptor(
                id: .optionalBindingShorthand, title: direction == .shorten ? "Use Short Optional Binding" : "Write Optional Binding Out",
                requiresSelection: false
            ))
        }
        return descriptors
    }

    public func plan(
        _ id: RefactoringID, context: RefactoringContext, parameters: [String: String]
    ) async throws -> WorkspaceEditPlan {
        let title = "Refactor"
        guard let text = Self.text(of: context.document), let url = context.documentURL ?? context.document.url else {
            return WorkspaceEditPlan(blockingError: "Save the file before refactoring.", title: title)
        }
        let map = SourceTextMap(text)
        let caret = map.byteOffset(utf16: context.cursor.position.utf16Offset)
        switch id {
        case .extractVariable:
            guard let selection = Self.selectionBytes(context.selection, map: map) else {
                return WorkspaceEditPlan(blockingError: "Select the expression to extract.", title: "Introduce Variable")
            }
            let name = parameters["name"] ?? "value"
            return Self.plan(SwiftIntroduceVariable.edits(in: text, selection: selection, name: name), text: text, url: url, title: "Introduce Variable")
        case .inlineVariable:
            return Self.plan(SwiftInlineVariable.edits(in: text, caret: caret), text: text, url: url, title: "Inline Variable")
        case .convertIfGuard:
            return Self.plan(SwiftConditionalConversion.edits(in: text, caret: caret), text: text, url: url, title: "Convert Between if and guard")
        case .moveToExtension:
            return Self.plan(SwiftMoveToExtension.edits(in: text, caret: caret), text: text, url: url, title: "Move to Extension")
        case .addExplicitType:
            return Self.plan(SwiftAddExplicitType.edits(in: text, caret: caret), text: text, url: url, title: "Add Explicit Type")
        case .optionalBindingShorthand:
            let allowed = SwiftToolsVersion.allowsOptionalBindingShorthand(forFileAt: url)
            return Self.plan(SwiftOptionalBindingShorthand.edits(in: text, caret: caret, allowsShorthand: allowed), text: text, url: url, title: "Optional Binding")
        case .safeDelete:
            return await safeDeletePlan(context: context, text: text, url: url, caret: caret)
        case .changeSignature:
            return await changeSignaturePlan(context: context, text: text, url: url, caret: caret, parameters: parameters)
        default:
            return WorkspaceEditPlan(blockingError: "That refactoring is not supported for Swift.", title: title)
        }
    }

    // MARK: - Change signature

    private func changeSignaturePlan(
        context: RefactoringContext, text: String, url: URL, caret: Int, parameters: [String: String]
    ) async -> WorkspaceEditPlan {
        let title = "Change Function Signature"
        guard let subject = SwiftChangeSignature.subject(in: text, caret: caret) else {
            return WorkspaceEditPlan(blockingError: "Place the caret on the function's name or parameters.", title: title)
        }
        guard var change = SwiftSignatureChange(json: parameters["parameters"]) else {
            return WorkspaceEditPlan(blockingError: "Enter a valid parameter list.", title: title)
        }
        change.oldShape = subject.shape
        if let problem = SwiftChangeSignature.problem(in: change, oldCount: subject.parameterCount) {
            return WorkspaceEditPlan(blockingError: problem, title: title)
        }
        if change.parameters == subject.parameters {
            return WorkspaceEditPlan(blockingError: "Nothing to change.", title: title)
        }

        // Every place the compiler's own resolution says the function is named: its declarations (overrides
        // and requirements included) and its calls, in any file.
        let map = SourceTextMap(text)
        let start = map.position(atByte: subject.nameBytes.lowerBound)
        let probe = NavigationContext(
            document: context.document, cursor: Cursor(position: start),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start))
        )
        let references: RenamePlan
        do { references = try await renamer.rename(probe, to: subject.name) } catch {
            return WorkspaceEditPlan(blockingError: error.localizedDescription, title: title)
        }
        if let blocked = references.blockingError { return WorkspaceEditPlan(blockingError: blocked, title: title) }

        var entries: [WorkspaceEditPlanEntry] = []
        var warnings: [String] = []
        let ambiguous = Set(references.entries.filter(\.isAmbiguous).map { "\($0.url.standardizedFileURL.path):\($0.range.start.utf16Offset)" })
        let byFile = Dictionary(grouping: references.entries, by: { $0.url.standardizedFileURL })
        for (fileURL, group) in byFile.sorted(by: { $0.key.path < $1.key.path }) {
            let fileText: String?
            if fileURL.path == url.standardizedFileURL.path { fileText = text } else { fileText = try? String(contentsOf: fileURL, encoding: .utf8) }
            guard let fileText else {
                warnings.append("\(fileURL.lastPathComponent) could not be read; its calls are unchanged.")
                continue
            }
            let fileMap = SourceTextMap(fileText)
            var names: [Range<Int>] = []
            for entry in group {
                let lower = fileMap.byteOffset(utf16: entry.range.start.utf16Offset)
                let range = lower ..< lower + subject.name.utf8.count
                if fileMap.text(bytes: range) == subject.name { names.append(range) }
            }
            let isDocument = fileURL.path == url.standardizedFileURL.path
            switch SwiftChangeSignature.edits(
                in: fileText, nameBytes: names, primary: isDocument ? subject.nameBytes : nil,
                oldCount: subject.parameterCount, change: change
            ) {
            case .failure(let failure):
                return WorkspaceEditPlan(blockingError: failure.message, title: title)
            case .success(let outcome):
                for edit in outcome.edits {
                    let wasAmbiguous = group.contains { entry in
                        ambiguous.contains("\(fileURL.path):\(entry.range.start.utf16Offset)")
                            && fileMap.byteOffset(utf16: entry.range.start.utf16Offset) <= edit.bytes.upperBound
                    }
                    entries.append(Self.entry(for: edit, text: fileText, map: fileMap, url: fileURL, description: "change parameters", ambiguous: wasAmbiguous && fileURL.path != url.standardizedFileURL.path))
                }
                for skipped in outcome.skipped {
                    let position = fileMap.position(atByte: skipped.lowerBound)
                    warnings.append("\(fileURL.lastPathComponent):\(position.line + 1) calls it in a form that cannot be changed automatically; edit it by hand.")
                }
            }
        }
        guard !entries.isEmpty else { return WorkspaceEditPlan(blockingError: "Nothing to change.", title: title) }
        return WorkspaceEditPlan(entries: entries, warnings: warnings, title: title)
    }

    // MARK: - Safe delete

    /// Deletes the declaration at the caret once the rename provider (the declaration family
    /// across files) shows nothing else uses it. A usage blocks the deletion and lists its files,
    /// as Java's safe delete does.
    private func safeDeletePlan(context: RefactoringContext, text: String, url: URL, caret: Int) async -> WorkspaceEditPlan {
        let title = "Safe Delete"
        guard let target = SwiftSafeDelete.target(in: text, caret: caret) else {
            return WorkspaceEditPlan(
                blockingError: "Place the caret on the name of a function, variable, type or enum case to delete.",
                title: title
            )
        }
        let edits: [SwiftTextEdit]
        switch SwiftSafeDelete.edits(in: text, caret: caret) {
        case .success(let found):
            edits = found
        case .failure(let failure):
            return WorkspaceEditPlan(blockingError: failure.message, title: title)
        }
        let map = SourceTextMap(text)
        let nameStart = map.position(atByte: target.nameBytes.lowerBound)
        let probe = NavigationContext(
            document: context.document, cursor: Cursor(position: nameStart),
            selection: Selection(range: EditorIntelligence.TextRange(start: nameStart, end: nameStart))
        )
        let renamed: RenamePlan
        do {
            renamed = try await renamer.rename(probe, to: target.name)
        } catch {
            return WorkspaceEditPlan(blockingError: error.localizedDescription, title: title)
        }
        if let blocked = renamed.blockingError {
            // The name resolves to nothing renamable: there is nothing safe to prove.
            return WorkspaceEditPlan(blockingError: blocked, title: title)
        }
        let ownURL = url.standardizedFileURL
        let usages = renamed.entries.filter {
            !($0.url.standardizedFileURL == ownURL && $0.range.start.utf16Offset == nameStart.utf16Offset)
        }
        if !usages.isEmpty {
            let files = Set(usages.map { $0.url.lastPathComponent }).sorted().joined(separator: ", ")
            let verb = usages.count == 1 ? "blocks" : "block"
            return WorkspaceEditPlan(
                blockingError: "\(usages.count) usage\(usages.count == 1 ? "" : "s") in \(files) \(verb) safe delete.",
                title: title
            )
        }
        return Self.plan(.success(edits), text: text, url: url, title: title)
    }

    // MARK: - Plans

    static func text(of document: Document) -> String? {
        guard document.languageIdentifier == SwiftAnalysis.languageIdentifier, !document.contentSnapshot.isElided else { return nil }
        let text = document.text
        return text.isEmpty ? nil : text
    }

    static func selectionBytes(_ selection: Selection, map: SourceTextMap) -> Range<Int>? {
        guard selection.additionalRanges.isEmpty, !selection.range.isEmpty else { return nil }
        let lower = map.byteOffset(utf16: selection.range.start.utf16Offset)
        let upper = map.byteOffset(utf16: selection.range.end.utf16Offset)
        return lower < upper ? lower ..< upper : nil
    }

    static func plan(_ result: SwiftRefactoringResult, text: String, url: URL, title: String) -> WorkspaceEditPlan {
        switch result {
        case .failure(let failure):
            return WorkspaceEditPlan(blockingError: failure.message, title: title)
        case .success(let edits):
            let map = SourceTextMap(text)
            return WorkspaceEditPlan(entries: edits.map { entry(for: $0, text: text, map: map, url: url, description: nil, ambiguous: false) }, title: title)
        }
    }

    static func entry(
        for edit: SwiftTextEdit, text: String, map: SourceTextMap, url: URL, description: String?, ambiguous: Bool
    ) -> WorkspaceEditPlanEntry {
        let range = map.range(bytes: edit.bytes)
        return WorkspaceEditPlanEntry(
            url: url, range: range, oldText: map.text(bytes: edit.bytes), newText: edit.replacement,
            lineText: map.lineContents(containingUTF16: range.start.utf16Offset).text, description: description, isAmbiguous: ambiguous
        )
    }
}
