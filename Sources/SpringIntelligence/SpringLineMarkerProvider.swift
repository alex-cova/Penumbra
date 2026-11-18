import EditorIntelligence
import Foundation

/// The marker kinds Spring contributes to the gutter. Declared once; Settings lists them under "Spring" and VoiceOver reads
/// their labels. Scheduled methods and Spring Data repositories are not here: nothing in the model recognises them yet, and a
/// marker without intelligence behind it would only decorate.
public enum SpringMarkers {
    public static let bean = LineMarkerDescriptor(
        id: "spring.bean", title: "Spring beans", group: "Spring", symbolName: "leaf.fill", tint: .success, priority: 40,
        accessibilityLabel: "Spring bean")
    public static let controller = LineMarkerDescriptor(
        id: "spring.controller", title: "Spring controllers", group: "Spring", symbolName: "network", tint: .accent, priority: 42,
        accessibilityLabel: "Spring controller")
    public static let repository = LineMarkerDescriptor(
        id: "spring.repository", title: "Spring repositories", group: "Spring", symbolName: "cylinder.split.1x2.fill", tint: .interface, priority: 42,
        accessibilityLabel: "Spring repository")
    public static let configuration = LineMarkerDescriptor(
        id: "spring.configuration", title: "Spring configuration classes", group: "Spring", symbolName: "gearshape.fill", tint: .neutral, priority: 41,
        accessibilityLabel: "Spring configuration class")
    public static let application = LineMarkerDescriptor(
        id: "spring.application", title: "Spring Boot applications", group: "Spring", symbolName: "bolt.fill", tint: .warning, priority: 45,
        accessibilityLabel: "Spring Boot application")
    public static let injection = LineMarkerDescriptor(
        id: "spring.injection", title: "Injection points", group: "Spring", symbolName: "arrow.down.right.circle.fill", tint: .accent, priority: 30,
        accessibilityLabel: "Injection point")

    public static let endpoint = LineMarkerDescriptor(
        id: "spring.endpoint", title: "Spring endpoints", group: "Spring", symbolName: "globe", tint: .accent, priority: 43,
        accessibilityLabel: "Spring endpoint")

    public static let all: [LineMarkerDescriptor] = [bean, controller, repository, configuration, application, injection, endpoint]

    /// Commands the host handles (`CodeActionCommand.id`).
    public enum Command {
        public static let reveal = "spring.revealInToolWindow"
        public static let dependencyGraph = "spring.showDependencyGraph"
        public static let contextGraph = "spring.showContextGraph"
        /// arguments: context id, endpoint id.
        public static let revealEndpoint = "spring.revealEndpoint"
        /// arguments: the text to copy (`GET /api/x`).
        public static let copyText = "spring.copyText"
        /// arguments: context id, endpoint id. Opens a new `.http` buffer; nothing is sent.
        public static let generateHTTPRequest = "spring.generateHTTPRequest"
    }
}

/// Spring's gutter markers for one Java file, from the application context(s) that include it: a marker on each bean class and
/// `@Bean` method (by what it is: controller, repository, configuration, application entry point, plain bean) and on each injection
/// point that has candidates. Every marker offers navigation or an action; none is decoration.
public struct SpringLineMarkerProvider: LineMarkerProviding {
    private let indexer: SpringWorkspaceIndexer
    public init(indexer: SpringWorkspaceIndexer) { self.indexer = indexer }

    struct Payload: Sendable {
        let beanID: SpringBeanID?
        let pointOwner: SpringBeanID?
        let contextID: String
        var point: SpringInjectionPoint? = nil
        var endpointIDs: [SpringEndpointID] = []
    }

    public func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? {
        guard let url = fileURL?.standardizedFileURL, await indexer.contains(url) else { return [] }
        await indexer.ingest(url: url, text: source)
        if Task.isCancelled { return nil }
        let store = indexer.store
        let contexts = await store.contexts(containing: url)
        let own = await store.moduleID(of: url)
        guard let context = contexts.first(where: { $0.moduleID == own }) ?? contexts.first else { return [] }
        let model = context.model
        let ranges = SpringTextRanges(text: source)
        var markers: [LineMarker] = []

        func marker(_ descriptor: LineMarkerDescriptor, at byteRange: Range<Int>, tooltip: String, payload: Payload) -> LineMarker {
            let p = ranges.position(byteRange.lowerBound)
            return LineMarker(descriptor: descriptor, line: p.line + 1, anchorUTF16Offset: p.utf16Offset, tooltip: tooltip, payload: payload)
        }

        for bean in model.beans where bean.location.url == url {
            let descriptor: LineMarkerDescriptor
            switch bean.origin {
            case .factoryMethod: descriptor = SpringMarkers.bean
            case .stereotype:
                let s = bean.stereotypes
                if s.contains(.springBootApplication) { descriptor = SpringMarkers.application }
                else if s.contains(.controller) || s.contains(.restController) { descriptor = SpringMarkers.controller }
                else if s.contains(.repository) { descriptor = SpringMarkers.repository }
                else if s.contains(.configuration) { descriptor = SpringMarkers.configuration }
                else { descriptor = SpringMarkers.bean }
            }
            let consumers = model.consumers(of: bean.id).count
            var tip = "Spring bean '\(bean.name)' (\(bean.type.simpleName))"
            if case .conditional(let reasons) = bean.certainty { tip += " — conditional: \(reasons.first ?? "")" }
            if case .inactive = bean.certainty { tip += " — inactive under the analysis profiles" }
            tip += consumers == 0 ? "" : " — injected in \(consumers) place\(consumers == 1 ? "" : "s")"
            markers.append(marker(descriptor, at: bean.location.byteRange, tooltip: tip, payload: Payload(beanID: bean.id, pointOwner: nil, contextID: context.id)))
        }
        for point in model.injectionPoints where point.location.url == url {
            let candidates = model.candidates(for: point)
            guard !candidates.isEmpty else { continue }
            let tip = candidates.count == 1
                ? "Injects Spring bean '\(candidates[0].name)'"
                : "\(candidates.count) candidate beans: \(candidates.map(\.name).joined(separator: ", "))"
            markers.append(marker(SpringMarkers.injection, at: point.nameRange, tooltip: tip,
                                  payload: Payload(beanID: nil, pointOwner: point.owner, contextID: context.id, point: point)))
        }
        // One marker per handler method, however many routes the mapping declares.
        if let index = await store.endpointIndex(contextID: context.id) {
            var byHandler: [Range<Int>: [SpringEndpoint]] = [:]
            for e in index.endpoints(in: url) where e.handlerLocation.url == url { byHandler[e.handlerLocation.byteRange, default: []].append(e) }
            for (range, list) in byHandler {
                let tip = list.count == 1 ? "\(list[0].title) — \(list[0].handlerTitle)"
                    : "\(list.count) endpoints: " + list.map(\.title).joined(separator: ", ")
                markers.append(marker(SpringMarkers.endpoint, at: range, tooltip: tip,
                                      payload: Payload(beanID: nil, pointOwner: nil, contextID: context.id, endpointIDs: list.map(\.id))))
            }
        }
        return markers.sorted { ($0.line, $0.anchorUTF16Offset) < ($1.line, $1.anchorUTF16Offset) }
    }

    public func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] { [] }

    public func menu(for marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [LineMarkerMenuItem] {
        guard let payload = marker.payload as? Payload, let url = fileURL?.standardizedFileURL,
              let context = await indexer.store.contexts().first(where: { $0.id == payload.contextID }) else { return [] }
        let model = context.model
        var items: [LineMarkerMenuItem] = []
        if !payload.endpointIDs.isEmpty, let index = await indexer.store.endpointIndex(contextID: context.id) {
            let list = payload.endpointIDs.compactMap(index.endpoint)
            for e in list.prefix(2) {
                items.append(LineMarkerMenuItem(title: "Reveal \(e.title) in Spring Endpoints", symbolName: "sidebar.left",
                                                action: .command(CodeActionCommand(id: SpringMarkers.Command.revealEndpoint, arguments: [context.id, e.id.raw]))))
                items.append(LineMarkerMenuItem(title: "Copy \(e.title)", symbolName: "doc.on.doc",
                                                action: .command(CodeActionCommand(id: SpringMarkers.Command.copyText, arguments: [e.title]))))
                items.append(LineMarkerMenuItem(title: "Generate HTTP Request for \(e.title)", symbolName: "paperplane",
                                                action: .command(CodeActionCommand(id: SpringMarkers.Command.generateHTTPRequest, arguments: [context.id, e.id.raw]))))
            }
            if let first = list.first {
                let target = await Self.locations(for: [(first.controllerLocation.url, first.controllerLocation.byteRange, first.controllerSimpleName)],
                                                  documentID: documentID, current: (url, source))
                items.append(LineMarkerMenuItem(title: "Go to Controller \(first.controllerSimpleName)", symbolName: "arrow.right.circle", action: .open(target)))
            }
            return items
        }
        if let id = payload.beanID, let bean = model.bean(id) {
            let consumers = model.consumers(of: id)
            if !consumers.isEmpty {
                let locations = await Self.locations(for: consumers.map { ($0.location.url, $0.nameRange, "\(model.bean($0.owner)?.name ?? $0.owner.raw).\($0.name)") }, documentID: documentID, current: (url, source))
                items.append(LineMarkerMenuItem(title: "Show \(consumers.count) injection point\(consumers.count == 1 ? "" : "s")", symbolName: "arrow.down.right.circle",
                                                action: .open(locations)))
            }
            if bean.stereotypes.contains(.controller) || bean.stereotypes.contains(.restController),
               let index = await indexer.store.endpointIndex(contextID: context.id) {
                let own = index.endpoints.filter { $0.controller == bean.type.name }
                if let first = own.first {
                    let targets = await Self.locations(for: own.map { ($0.handlerLocation.url, $0.handlerLocation.byteRange, $0.title) },
                                                       documentID: documentID, current: (url, source))
                    items.append(LineMarkerMenuItem(title: "Show \(own.count) endpoint\(own.count == 1 ? "" : "s")", symbolName: "globe", action: .open(targets)))
                    items.append(LineMarkerMenuItem(title: "Reveal Endpoints in Spring Tool Window", symbolName: "sidebar.left",
                                                    action: .command(CodeActionCommand(id: SpringMarkers.Command.revealEndpoint, arguments: [context.id, first.id.raw]))))
                }
            }
            items.append(LineMarkerMenuItem(title: "Find Usages", symbolName: "magnifyingglass", action: .navigate(.references)))
            items.append(LineMarkerMenuItem(title: "Reveal in Spring Tool Window", symbolName: "sidebar.left",
                                            action: .command(CodeActionCommand(id: SpringMarkers.Command.reveal, arguments: [context.id, id.raw]))))
            items.append(LineMarkerMenuItem(title: "Show in Dependency Graph", symbolName: "point.3.connected.trianglepath.dotted",
                                            action: .command(CodeActionCommand(id: SpringMarkers.Command.dependencyGraph, arguments: [context.id, id.raw]))))
            if bean.stereotypes.contains(.springBootApplication) || bean.stereotypes.contains(.configuration) {
                items.append(LineMarkerMenuItem(title: "Show Application Context Graph", symbolName: "square.stack.3d.up",
                                                action: .command(CodeActionCommand(id: SpringMarkers.Command.contextGraph, arguments: [context.id]))))
            }
        } else if let point = payload.point {
            let candidates = model.candidates(for: point)
            let locations = await Self.locations(for: candidates.map { ($0.location.url, $0.location.byteRange, "\($0.name) — \($0.type.simpleName)") },
                                                 documentID: documentID, current: (url, source))
            items.append(LineMarkerMenuItem(title: candidates.count == 1 ? "Go to bean '\(candidates[0].name)'" : "Go to one of \(candidates.count) candidate beans",
                                            symbolName: "arrow.right.circle", action: .open(locations)))
            if let first = candidates.first {
                items.append(LineMarkerMenuItem(title: "Show in Dependency Graph", symbolName: "point.3.connected.trianglepath.dotted",
                                                action: .command(CodeActionCommand(id: SpringMarkers.Command.dependencyGraph, arguments: [context.id, point.owner.raw]))))
                _ = first
            }
        }
        return items
    }

    private static func locations(for targets: [(URL, Range<Int>, String)], documentID: DocumentID, current: (URL, String)) async -> [Location] {
        var cache: [URL: SpringTextRanges] = [current.0: SpringTextRanges(text: current.1)]
        return targets.compactMap { (target, range, title) in
            if cache[target] == nil, let text = try? String(contentsOf: target, encoding: .utf8) { cache[target] = SpringTextRanges(text: text) }
            guard let ranges = cache[target] else { return nil }
            return Location(documentID: target == current.0 ? documentID : DocumentID(), url: target, range: ranges.range(range), displayName: title)
        }
    }
}
