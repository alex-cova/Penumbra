import AppKit
import EditorIntelligence
import Penumbra

/// Usages and type/call-hierarchy navigation: showing the tabs, pinning snapshots of them,
/// and jumping from a node to its file. State (the stores, pins, selection) stays on
/// `IDEWorkspace`; this file holds the operations, matching the +Breakpoints/+Run splits.
extension IDEWorkspace {
        // MARK: Usages

        func closeUsages() {
            usages.clear()
            deselectBottomTab(.usages)
        }

        func closeTestResults() {
            testResults.clear()
            deselectBottomTab(.testResults)
        }

        // MARK: Type hierarchy

        /// Shows the hierarchy of the type at the active editor's caret (⌃H). Always handles the
        /// request: outside a Java type the tab says so instead of the key doing nothing.
        @discardableResult
        func showTypeHierarchy() -> Bool {
            showHierarchy(kind: .type)
        }

        /// Shows the hierarchy of the method at the active editor's caret (⇧⌘H): the classes that
        /// declare it and the ones below them, each marked by what it does with it.
        @discardableResult
        func showMethodHierarchy() -> Bool {
            showHierarchy(kind: .method)
        }

        private func showHierarchy(kind: IDETypeHierarchyStore.Kind) -> Bool {
            let host = host(for: workbench.activePane.id)
            let textView = host.textView
            let url = textView.documentURL
            let languageIdentifier = workbench.activePane.selectedDocument?.languageIdentifier
            // A new request goes to the live view, whichever pinned one was showing.
            selectedTypeHierarchyPinID = nil
            // Each store keeps its own provider lookup, so a pinned copy still expands after the live
            // view has moved on to another kind or language.
            typeHierarchy.loader = { [weak self] node, direction, scope, file in
                guard let provider = self?.typeHierarchyProvider(kind: kind, language: languageIdentifier) else { return [] }
                switch direction {
                case .supertypes: return await provider.supertypes(of: node, file: file)
                case .subtypes: return await provider.subtypes(of: node, file: file, scope: scope)
                }
            }
            guard let provider = typeHierarchyProvider(kind: kind, language: languageIdentifier) else {
                typeHierarchy.show(message: "\(kind.title) is not available for \(IDELanguageSupport.displayName(forIdentifier: languageIdentifier)) files")
                showBottomTab(.typeHierarchy)
                return true
            }
            let source = textView.text
            let offset = textView.selectedRange.location
            Task { [weak self] in
                let root = await provider.rootItem(source: source, fileURL: url, utf16Offset: offset)
                guard let self else { return }
                if let root {
                    self.typeHierarchy.show(root: root, file: url, kind: kind, languageIdentifier: languageIdentifier)
                } else {
                    self.typeHierarchy.show(message: kind == .method ? "No method at the caret" : "No type at the caret")
                }
                self.showBottomTab(.typeHierarchy)
            }
            return true
        }

        private func typeHierarchyProvider(kind: IDETypeHierarchyStore.Kind, language: String?) -> (any TypeHierarchyProviding)? {
            kind == .method ? languages.methodHierarchy(for: language) : languages.typeHierarchy(for: language)
        }

        /// Closes what the Type Hierarchy tab shows: a pinned hierarchy goes, the live one is cleared.
        /// The tab itself goes when nothing is left.
        func closeTypeHierarchy() {
            if let pin = selectedTypeHierarchyPinID {
                unpinTypeHierarchy(pin)
            } else {
                typeHierarchy.clear()
            }
            if !showsTypeHierarchyTab { deselectBottomTab(.typeHierarchy) }
        }

        /// Pin Tab: keeps the hierarchy on screen as a copy, so the next one opens in the live view.
        func pinTypeHierarchy() {
            let store = visibleTypeHierarchy
            guard let root = store.root, selectedTypeHierarchyPinID == nil else { return }
            let pin = IDEPinnedHierarchy(title: "\(store.kind.title): \(root.name)", store: store.copy())
            pinnedTypeHierarchies.append(pin)
            selectedTypeHierarchyPinID = pin.id
        }

        func unpinTypeHierarchy(_ id: UUID) {
            pinnedTypeHierarchies.removeAll { $0.id == id }
            if selectedTypeHierarchyPinID == id { selectedTypeHierarchyPinID = nil }
            if !showsTypeHierarchyTab { deselectBottomTab(.typeHierarchy) }
        }

        /// Opens the declaration of a hierarchy node: in the project, or in an attached source. A type
        /// with no source (a class file) has nowhere to go, so the system beeps.
        func openTypeHierarchyNode(_ node: HierarchyItem, in store: IDETypeHierarchyStore) {
            guard let provider = typeHierarchyProvider(kind: store.kind, language: store.languageIdentifier) else { return }
            let file = store.file
            Task { [weak self] in
                guard let location = await provider.location(of: node, file: file), let url = location.url else {
                    NSSound.beep()
                    return
                }
                _ = self?.openNavigationLocation(Location(
                    documentID: DocumentID(), url: url, range: location.range, displayName: node.name
                ))
            }
        }

        // MARK: Call hierarchy

        @discardableResult
        func showCallHierarchy() -> Bool {
            let host = host(for: workbench.activePane.id)
            let textView = host.textView
            let url = textView.documentURL
            let languageIdentifier = workbench.activePane.selectedDocument?.languageIdentifier
            selectedCallHierarchyPinID = nil
            callHierarchy.loader = { [weak self] node, direction, scope, file in
                guard let provider = self?.languages.callHierarchy(for: languageIdentifier) else { return [] }
                switch direction {
                case .callers: return await provider.callers(of: node, file: file, scope: scope)
                case .callees: return await provider.callees(of: node, file: file)
                }
            }
            guard let provider = languages.callHierarchy(for: languageIdentifier) else {
                callHierarchy.show(message: "Call Hierarchy is not available for \(IDELanguageSupport.displayName(forIdentifier: languageIdentifier)) files")
                showBottomTab(.callHierarchy)
                return true
            }
            let source = textView.text
            let offset = textView.selectedRange.location
            Task { [weak self] in
                let root = await provider.rootItem(source: source, fileURL: url, utf16Offset: offset)
                guard let self else { return }
                if let root {
                    self.callHierarchy.show(root: root, file: url, languageIdentifier: languageIdentifier)
                } else {
                    self.callHierarchy.show(message: "No method or field at the caret")
                }
                self.showBottomTab(.callHierarchy)
            }
            return true
        }

        func closeCallHierarchy() {
            if let pin = selectedCallHierarchyPinID {
                unpinCallHierarchy(pin)
            } else {
                callHierarchy.clear()
            }
            if !showsCallHierarchyTab { deselectBottomTab(.callHierarchy) }
        }

        func pinCallHierarchy() {
            let store = visibleCallHierarchy
            guard let root = store.root, selectedCallHierarchyPinID == nil else { return }
            let pin = IDEPinnedHierarchy(title: "Call Hierarchy: \(root.name)", store: store.copy())
            pinnedCallHierarchies.append(pin)
            selectedCallHierarchyPinID = pin.id
        }

        func unpinCallHierarchy(_ id: UUID) {
            pinnedCallHierarchies.removeAll { $0.id == id }
            if selectedCallHierarchyPinID == id { selectedCallHierarchyPinID = nil }
            if !showsCallHierarchyTab { deselectBottomTab(.callHierarchy) }
        }

        func openCallHierarchyNode(_ node: HierarchyItem, in store: IDECallHierarchyStore) {
            guard let provider = languages.callHierarchy(for: store.languageIdentifier) else { return }
            let file = store.file
            Task { [weak self] in
                guard let location = await provider.location(of: node, file: file), let url = location.url else {
                    NSSound.beep()
                    return
                }
                _ = self?.openNavigationLocation(Location(
                    documentID: DocumentID(), url: url, range: location.range, displayName: node.name
                ))
            }
        }
}
