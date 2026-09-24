import EditorIntelligence
import Foundation

/// Selection-based refactorings for Java (extract variable, field, constant, …).
public actor JavaRefactoringProvider: RefactoringProviding {
    let index: JavaIndex
    private let cacheRoot: URL
    private let candidates: any JavaUsageCandidateSource
    private var gradleModel: JavaGradleProjectModel?
    private var indexPaths: JavaIndexPaths?
    private var jdkHome: URL?
    private var roots: [URL] = []
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths, candidates: any JavaUsageCandidateSource) {
        self.index = index
        self.cacheRoot = indexPaths.root
        self.indexPaths = indexPaths
        self.candidates = candidates
    }

    public func setGradleModel(_ model: JavaGradleProjectModel?) { gradleModel = model }
    public func setJDKHome(_ home: URL?) { jdkHome = home }
    public func setRoots(_ roots: [URL]) { self.roots = roots.map(\.standardizedFileURL) }
    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) { openBuffer = lookup }

    // MARK: - RefactoringProviding

    public func availableRefactorings(_ context: RefactoringContext) async -> [RefactoringDescriptor] {
        guard context.document.languageIdentifier == "java" else { return [] }
        let source = JavaRefactoringText.fullText(of: context.document)
        guard !source.isEmpty,
              let url = context.documentURL ?? context.document.url else { return [] }

        var descriptors: [RefactoringDescriptor] = []
        if !context.selection.isEmpty {
            let variableName = await JavaExtractVariable.suggestedName(
                source: source, selection: context.selection, url: url, index: index
            ) ?? "result"
            let fieldName = await JavaExtractField.suggestedName(
                source: source, selection: context.selection, url: url, index: index
            ) ?? "result"
            let constantName = await JavaExtractConstant.suggestedName(
                source: source, selection: context.selection, url: url, index: index
            ) ?? "RESULT"
            let methodName = await JavaExtractMethod.suggestedName(
                source: source, selection: context.selection, url: url, index: index
            ) ?? "extractedMethod"
            descriptors += [
                RefactoringDescriptor(
                    id: .extractVariable,
                    title: "Extract Variable…",
                    requiresSelection: true,
                    parameterKeys: ["name"],
                    suggestedParameters: ["name": variableName]
                ),
                RefactoringDescriptor(
                    id: .extractField,
                    title: "Extract Field…",
                    requiresSelection: true,
                    parameterKeys: ["name"],
                    suggestedParameters: ["name": fieldName]
                ),
                RefactoringDescriptor(
                    id: .extractConstant,
                    title: "Extract Constant…",
                    requiresSelection: true,
                    parameterKeys: ["name"],
                    suggestedParameters: ["name": constantName]
                ),
                RefactoringDescriptor(
                    id: .extractMethod,
                    title: "Extract Method…",
                    requiresSelection: true,
                    parameterKeys: ["name"],
                    suggestedParameters: ["name": methodName]
                )
            ]
        }
        if await JavaInlineVariable.isAvailable(source: source, context: context, url: url, index: index) {
            descriptors.append(RefactoringDescriptor(id: .inlineVariable, title: "Inline Variable", requiresSelection: false))
        }
        if await JavaInlineMethod.isAvailable(source: source, context: context, url: url, index: index, cacheRoot: cacheRoot) {
            descriptors.append(RefactoringDescriptor(id: .inlineMethod, title: "Inline Method", requiresSelection: false))
        }
        let environment = makeEnvironment(for: context)
        if let field = await JavaEncapsulateField.fieldContext(
            source: source, url: url, caretUTF16: context.cursor.position.utf16Offset, index: index, environment: environment
        ) {
            if JavaEncapsulateField.canEncapsulate(field) {
                descriptors.append(RefactoringDescriptor(id: .encapsulateField, title: "Encapsulate Field", requiresSelection: false))
            }
            if JavaEncapsulateField.canGenerateAccessors(field) {
                descriptors.append(RefactoringDescriptor(id: .generateAccessors, title: "Generate Getter and Setter", requiresSelection: false))
            }
        }
        if let suggested = await JavaChangeSignature.suggestedParameters(
            source: source, caretOffset: context.cursor.position.utf16Offset, url: url, environment: environment
        ) {
            descriptors.append(RefactoringDescriptor(
                id: .changeSignature,
                title: "Change Method Signature…",
                requiresSelection: false,
                parameterKeys: ["newName", "addParameterType", "addParameterName", "addParameterDefault", "removeLastParameter"],
                suggestedParameters: suggested
            ))
        }
        if await JavaMoveClass.isAvailable(
            source: source, caretOffset: context.cursor.position.utf16Offset, url: url, environment: environment, index: index
        ) {
            descriptors.append(RefactoringDescriptor(
                id: .moveClass,
                title: "Move Class…",
                requiresSelection: false,
                parameterKeys: ["targetPackage"],
                suggestedParameters: ["targetPackage": ""]
            ))
        }
        if await JavaSafeDelete.isAvailable(
            source: source, caretOffset: context.cursor.position.utf16Offset, url: url, environment: environment, index: index
        ) {
            descriptors.append(RefactoringDescriptor(id: .safeDelete, title: "Safe Delete", requiresSelection: false))
        }
        return descriptors
    }

    public func plan(
        _ id: RefactoringID, context: RefactoringContext, parameters: [String: String]
    ) async throws -> WorkspaceEditPlan {
        guard context.document.languageIdentifier == "java" else {
            return WorkspaceEditPlan(blockingError: "This refactoring is only available in Java files.")
        }
        let source = JavaRefactoringText.fullText(of: context.document)
        guard !source.isEmpty else {
            return WorkspaceEditPlan(blockingError: "The file is empty.")
        }
        guard let url = context.documentURL ?? context.document.url else {
            return WorkspaceEditPlan(blockingError: "Save the file before refactoring.")
        }

        switch id {
        case .extractVariable, .extractField, .extractConstant, .extractMethod:
            guard !context.selection.isEmpty else {
                return WorkspaceEditPlan(blockingError: "Select an expression to extract.")
            }
            guard let name = parameters["name"], !name.isEmpty else {
                return WorkspaceEditPlan(blockingError: "Enter a name.")
            }
            switch id {
            case .extractVariable:
                return await JavaExtractVariable.plan(
                    source: source, selection: context.selection, url: url, name: name, index: index
                )
            case .extractField:
                return await JavaExtractField.plan(
                    source: source, selection: context.selection, url: url, name: name, index: index
                )
            case .extractConstant:
                return await JavaExtractConstant.plan(
                    source: source, selection: context.selection, url: url, name: name, index: index
                )
            case .extractMethod:
                return await JavaExtractMethod.plan(
                    source: source, selection: context.selection, url: url, name: name, index: index
                )
            default:
                break
            }
        case .inlineVariable:
            return await JavaInlineVariable.plan(source: source, context: context, url: url, index: index)
        case .inlineMethod:
            return await JavaInlineMethod.plan(source: source, context: context, url: url, index: index, cacheRoot: cacheRoot)
        case .changeSignature:
            guard let request = parseChangeSignatureRequest(parameters) else {
                return WorkspaceEditPlan(blockingError: "Enter a valid method signature change.", title: JavaChangeSignature.title)
            }
            return await JavaChangeSignature.plan(
                source: source, caretOffset: context.cursor.position.utf16Offset, url: url, request: request,
                index: index, candidates: candidates, roots: roots,
                environment: makeEnvironment(for: context), isReadOnly: readOnlyChecker
            )
        case .encapsulateField, .generateAccessors:
            let environment = makeEnvironment(for: context)
            guard let field = await JavaEncapsulateField.fieldContext(
                source: source, url: url, caretUTF16: context.cursor.position.utf16Offset, index: index, environment: environment
            ) else {
                return WorkspaceEditPlan(blockingError: "Place the caret on a field name.", title: "Refactoring")
            }
            if id == .encapsulateField {
                return await JavaEncapsulateField.encapsulatePlan(
                    field: field, roots: roots, candidates: candidates, environment: environment
                )
            }
            return await JavaEncapsulateField.generateAccessorsPlan(field: field)
        case .moveClass:
            let targetPackage = parameters["targetPackage"] ?? ""
            return await JavaMoveClass.plan(
                source: source, caretOffset: context.cursor.position.utf16Offset, url: url, targetPackage: targetPackage,
                index: index, candidates: candidates, roots: roots,
                environment: makeEnvironment(for: context), isReadOnly: readOnlyChecker
            )
        case .safeDelete:
            return await JavaSafeDelete.plan(
                source: source, caretOffset: context.cursor.position.utf16Offset, url: url,
                index: index, candidates: candidates, roots: roots,
                environment: makeEnvironment(for: context), isReadOnly: readOnlyChecker
            )
        default:
            return WorkspaceEditPlan(blockingError: "That refactoring is not supported.", title: "Refactoring")
        }
        return WorkspaceEditPlan(blockingError: "That refactoring is not supported.", title: "Refactoring")
    }

    // MARK: - Change signature

    private func parseChangeSignatureRequest(_ parameters: [String: String]) -> JavaChangeSignature.Request? {
        guard let newName = parameters["newName"], !newName.isEmpty else { return nil }
        let removeLast = parameters["removeLastParameter"] == "true"
        let type = parameters["addParameterType"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = parameters["addParameterName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultValue = parameters["addParameterDefault"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let add: (type: String, name: String, defaultValue: String)?
        if !type.isEmpty || !name.isEmpty || !defaultValue.isEmpty {
            guard !type.isEmpty, !name.isEmpty, !defaultValue.isEmpty else { return nil }
            add = (type, name, defaultValue)
        } else {
            add = nil
        }
        return JavaChangeSignature.Request(newName: newName, addParameter: add, removeLastParameter: removeLast)
    }

    private func makeEnvironment(for context: RefactoringContext) -> JavaReferenceEnvironment {
        let base = openBuffer
        let documentURL = context.document.url?.standardizedFileURL
        let documentText = JavaRefactoringText.fullText(of: context.document)
        let lookup: @Sendable (URL) async -> String? = { url in
            if let documentURL, url.standardizedFileURL.path == documentURL.path, !documentText.isEmpty { return documentText }
            return await base?(url)
        }
        return JavaReferenceEnvironment(
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: lookup,
            gradleModel: gradleModel, indexPaths: indexPaths
        )
    }

    private var readOnlyChecker: @Sendable (URL) -> Bool {
        let gradleModel = gradleModel
        return { url in
            let path = url.standardizedFileURL.path
            if path.contains("/build/generated/") { return true }
            if let gradleModel {
                return gradleModel.existingGeneratedSourceDirectories.contains {
                    path.hasPrefix($0.standardizedFileURL.path.hasSuffix("/") ? $0.path : $0.path + "/")
                }
            }
            return false
        }
    }

    private func isReadOnly(_ url: URL) -> Bool {
        readOnlyChecker(url)
    }
}
