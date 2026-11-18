import Foundation
import JavaIntelligence

/// The incremental store behind ``SpringModel``.
///
/// Files enter as source text and are reduced to ``JavaFileDeclarations`` (the Java layer's one
/// annotation-aware extraction). A file edit whose *Spring-relevant signature* is unchanged (a
/// method-body edit, whitespace, comments) only refreshes stored locations and leaves the cached
/// model valid, so typing inside a method never rebuilds the bean graph. Any other change bumps
/// ``revision`` and the model is rebuilt lazily on the next ``model()`` call.
///
/// The rebuild is whole-project, over already-extracted declarations (no parsing). Per-bean
/// invalidation is a later optimisation gated on a benchmark, not assumed.
public actor SpringProjectModel {
    private var files: [URL: JavaFileDeclarations] = [:]
    private var signatures: [URL: Int] = [:]
    /// Hash of the last text each file was extracted from, so an unchanged buffer is not parsed again.
    private var textHashes: [URL: Int] = [:]
    private var profiles: Set<String>?
    private var cached: SpringModel?
    public private(set) var revision = 0

    // Configuration files and metadata (see ``config()``).
    private var configFiles: [URL: SpringConfigFile] = [:]
    private var configHashes: [URL: Int] = [:]
    private var externalMetadata = SpringConfigMetadata.empty
    private var resourceRoots: [URL] = []
    private var cachedConfig: SpringConfigModel?
    private var modules: [SpringModuleInfo] = []
    private var cachedContexts: [SpringApplicationContext]?
    /// The application classes depend only on the sources, so a profile switch or a module change keeps them.
    private var cachedApplications: [SpringApplicationEntry]?
    public private(set) var configRevision = 0

    // Endpoints: extracted per controller and kept until a file the controller depends on changes.
    private var fileEpochs: [URL: Int] = [:]
    private var webSignatures: [URL: Int] = [:]
    private var endpointFiles = Set<URL>()
    private struct CachedExtraction { let extraction: SpringControllerExtraction; let epochs: [URL: Int] }
    private struct CachedAdvice {
        let refs: [SpringExceptionHandlerRef]; let selector: SpringEndpointExtractor.AdviceSelector; let epochs: [URL: Int]
    }
    private var extractionCache: [String: CachedExtraction] = [:]
    private var adviceCache: [String: CachedAdvice] = [:]
    private var cachedEndpointIndexes: [SpringEndpointIndex]?
    /// Moves when anything the endpoint index depends on changed; the tool window compares it with its snapshot.
    public private(set) var endpointRevision = 0
    /// Controllers read from source since the store was made: tests and benchmarks use it to show what an edit re-reads.
    public private(set) var extractionCount = 0

    public init(activeProfiles: Set<String>? = nil) { profiles = activeProfiles }

    /// Whether the file's Spring-relevant declarations changed (so ``revision`` moved).
    @discardableResult
    public func update(url: URL, source: String) -> Bool {
        let hash = source.hashValue
        if textHashes[url] == hash, signatures[url] != nil { return false }
        textHashes[url] = hash
        let declarations = JavaDeclaredAnnotations.extract(source: source)
        return update(url: url, declarations: declarations)
    }

    @discardableResult
    public func update(url: URL, declarations: JavaFileDeclarations) -> Bool {
        let sig = Self.signature(of: declarations)
        let web = Self.webSignature(of: declarations)
        let relevant = declarations.types.isEmpty ? nil : declarations
        // Endpoints read mapping annotations, parameters and return types, which the bean model ignores. A change there (or a
        // shifted range in a file a cached controller depends on) refreshes the endpoint cache without rebuilding any context.
        var endpointsChanged = false
        if webSignatures[url] != web {
            webSignatures[url] = web
            touchEndpoints(url)
            endpointsChanged = true
        } else if endpointFiles.contains(url), files[url] != declarations {
            touchEndpoints(url)
        }
        if signatures[url] == sig, files[url] != nil || relevant == nil {
            if relevant != nil { files[url] = declarations }   // refresh byte ranges only
            return endpointsChanged
        }
        signatures[url] = sig
        if let relevant { files[url] = relevant } else { files.removeValue(forKey: url) }
        extractionCache.removeAll(); adviceCache.removeAll()   // a type appeared or vanished: names may resolve differently
        invalidate()
        return true
    }

    public func remove(url: URL) {
        signatures.removeValue(forKey: url)
        textHashes.removeValue(forKey: url)
        webSignatures.removeValue(forKey: url)
        touchEndpoints(url)
        if files.removeValue(forKey: url) != nil { extractionCache.removeAll(); adviceCache.removeAll(); invalidate() }
    }

    /// `nil` means "unknown": `@Profile` beans are then conditional rather than active or inactive.
    public func setActiveProfiles(_ profiles: Set<String>?) {
        guard profiles != self.profiles else { return }
        self.profiles = profiles
        invalidate(sources: false)
    }

    /// Parses `application*` configuration (or an imported file) and stores it; false when the text is unchanged.
    @discardableResult
    public func updateConfig(url: URL, text: String, allowAnyName: Bool = false) -> Bool {
        let hash = text.hashValue
        if configHashes[url] == hash, configFiles[url] != nil { return false }
        configHashes[url] = hash
        var parsed = SpringConfigParser.parse(url: url, text: text)
        if parsed == nil, allowAnyName {
            let ext = url.pathExtension.lowercased()
            let format: SpringConfigFormat = ext == "properties" ? .properties : .yaml
            if ["properties", "yml", "yaml"].contains(ext) {
                let (entries, docs) = format == .properties ? SpringConfigParser.parseProperties(text) : SpringConfigParser.parseYAML(text)
                parsed = SpringConfigFile(url: url, format: format, fileProfile: nil, entries: entries, documentProfiles: docs)
            }
        }
        guard let parsed else { return false }
        configFiles[url] = parsed
        invalidateConfig()
        return true
    }

    public func removeConfig(url: URL) {
        configHashes.removeValue(forKey: url)
        if configFiles.removeValue(forKey: url) != nil { invalidateConfig() }
    }

    /// Folders `classpath:` imports resolve against; set before the first scan so imports follow on it.
    public func setResourceRoots(_ roots: [URL]) {
        guard roots != resourceRoots else { return }
        resourceRoots = roots
        invalidateConfig()
    }

    public func configFileURLs() -> Set<URL> { Set(configFiles.keys) }

    /// Metadata read from the project's jars and build output (library keys, types, defaults, deprecations).
    public func setExternalMetadata(_ metadata: SpringConfigMetadata, resourceRoots: [URL]) {
        externalMetadata = metadata
        self.resourceRoots = resourceRoots
        invalidateConfig()
    }

    /// Configuration files, merged metadata (project `@ConfigurationProperties` first, then libraries) and the
    /// queries over them. Rebuilt only when a config file, the metadata, the profiles or the Java model changed.
    public func config() -> SpringConfigModel {
        if let cachedConfig { return cachedConfig }
        let java = model()
        var merged = SpringConfigMetadata()
        for p in java.configurationProperties { merged.add(p) }
        merged.merge(externalMetadata)
        let built = SpringConfigModel(files: Array(configFiles.values), metadata: merged, model: java,
                                      analysisProfiles: profiles, resourceRoots: resourceRoots)
        cachedConfig = built
        return built
    }

    private func invalidateConfig() { cachedConfig = nil; configRevision += 1 }

    /// The build modules the sources belong to, with their project dependencies. Without them every file is one module.
    public func setModules(_ modules: [SpringModuleInfo]) {
        guard modules != self.modules else { return }
        self.modules = modules
        invalidate(sources: false)
    }

    /// One context per Spring Boot application (see ``SpringApplicationContext``), or a single `default` context over
    /// every source when the project has no application class. Cached until a Spring-relevant change.
    public func contexts() -> [SpringApplicationContext] {
        if let cachedContexts { return cachedContexts }
        var finder = SpringModelBuilder(files: files, activeProfiles: profiles)
        let applications = cachedApplications ?? finder.findApplications()
        cachedApplications = applications
        var result: [SpringApplicationContext] = []
        if applications.isEmpty {
            let all = model()
            result = [SpringApplicationContext(
                id: "default", name: "Spring application", entry: nil, moduleID: nil, moduleIDs: modules.map(\.projectPath),
                scanPackages: [], importedTypes: [], fileURLs: Set(files.keys), model: all)]
        } else {
            for app in applications.sorted(by: { $0.typeName < $1.typeName }) {
                result.append(buildContext(for: app))
            }
        }
        cachedContexts = result
        return result
    }

    /// The module (project path) that owns a source file: the one with the longest matching source root.
    public func moduleID(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        var best: (String, Int)?
        for m in modules {
            for root in m.sourceRoots {
                let r = root.standardizedFileURL.path
                if path.hasPrefix(r + "/"), r.count > (best?.1 ?? -1) { best = (m.projectPath, r.count) }
            }
        }
        return best?.0
    }

    /// Contexts whose sources include `url`.
    public func contexts(containing url: URL) -> [SpringApplicationContext] {
        let u = url.standardizedFileURL
        return contexts().filter { $0.fileURLs.contains(u) }
    }

    /// The model to answer a request about `url`: the context of the application it belongs to (the one whose own module
    /// it is in, else the first by name); empty when no application reaches the file, so a class outside every scan
    /// gets no bean intelligence it would not have at runtime.
    public func model(for url: URL) -> SpringModel {
        let containing = contexts(containing: url)
        let own = moduleID(of: url)
        return (containing.first { $0.moduleID == own } ?? containing.first)?.model ?? .empty
    }

    private func buildContext(for app: SpringApplicationEntry) -> SpringApplicationContext {
        let entryModule = moduleID(of: app.location.url)
        var scopeModules = Set<String>()
        if let entryModule {
            scopeModules.insert(entryModule)
            scopeModules.formUnion(modules.first { $0.projectPath == entryModule }?.dependencyPaths ?? [])
        }
        let roots: [String] = modules.filter { scopeModules.contains($0.projectPath) }.flatMap(\.sourceRoots).map { $0.standardizedFileURL.path }
        let scoped = (entryModule == nil || modules.isEmpty) ? files : files.filter { url, _ in
            roots.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") }
        }
        var packages = Set<String>(), imports: Set<String> = [app.typeName]
        var model = SpringModel.empty
        // Grow the scope until the configuration classes it registers ask for nothing new.
        for _ in 0..<6 {
            var builder = SpringModelBuilder(files: scoped, activeProfiles: profiles, scope: .scan(packages: packages, imported: imports))
            model = builder.build()
            let newPackages = model.discoveredScanPackages.subtracting(packages)
            let newImports = model.discoveredImports.subtracting(imports)
            if newPackages.isEmpty && newImports.isEmpty { break }
            packages.formUnion(newPackages); imports.formUnion(newImports)
        }
        let name = app.typeName.split(separator: ".").last.map(String.init) ?? app.typeName
        return SpringApplicationContext(
            id: app.typeName, name: name, entry: app, moduleID: entryModule, moduleIDs: scopeModules.sorted(),
            scanPackages: packages.sorted(), importedTypes: imports.subtracting([app.typeName]).sorted(),
            fileURLs: Set(scoped.keys), model: model)
    }

    /// The whole source set analysed without application boundaries (every stereotype class is a bean). Providers ask
    /// ``model(for:)`` instead; this is what a project without an application class, and the tests, use.
    public func model() -> SpringModel {
        if let cached { return cached }
        var builder = SpringModelBuilder(files: files, activeProfiles: profiles)
        let built = builder.build()
        cached = built
        return built
    }

    public func removeAll() {
        guard !files.isEmpty || !signatures.isEmpty || !configFiles.isEmpty else { return }
        files = [:]; signatures = [:]; textHashes = [:]; webSignatures = [:]
        extractionCache = [:]; adviceCache = [:]; endpointFiles = []
        configFiles = [:]; configHashes = [:]; externalMetadata = .empty
        invalidate()
    }

    /// Drops what depends on `sources` (every parse changed) or only on settings (profiles, modules: the application classes stay).
    private func invalidate(sources: Bool = true) {
        cached = nil; cachedConfig = nil; cachedContexts = nil; cachedEndpointIndexes = nil; revision += 1; endpointRevision += 1
        if sources { cachedApplications = nil }
    }

    /// What the bean model reads, without byte ranges (shifting a declaration is not a change) and without what only the endpoint
    /// index reads: Spring web annotations, and plain methods that take part in no injection. Editing a mapping, a parameter
    /// binding or a handler's return type therefore leaves every context untouched; ``webSignature(of:)`` sees those edits.
    static func signature(of f: JavaFileDeclarations) -> Int {
        var h = Hasher()
        h.combine(f.packageName)
        for i in f.imports { h.combine(i) }
        for t in f.types {
            h.combine(t.qualifiedName); h.combine(t.kind); h.combine(t.modifiers.rawValue)
            hash(t.annotations, &h, beansOnly: true); h.combine(t.superclass); h.combine(t.interfaces)
            for fl in t.fields { h.combine(fl.name); h.combine(fl.type); h.combine(fl.modifiers.rawValue); hash(fl.annotations, &h, beansOnly: true) }
            for m in t.methods {
                // A method matters to the bean model when it is a constructor or carries an annotation other than a web one
                // (`@Bean`, `@Autowired`, a composed annotation…). A handler carrying only mapping annotations does not.
                guard m.isConstructor || m.annotations.contains(where: { !SpringWebAnnotations.webOnly.contains($0.simpleName) }) else { continue }
                h.combine(m.name); h.combine(m.returnType); h.combine(m.modifiers.rawValue); h.combine(m.isConstructor)
                hash(m.annotations, &h, beansOnly: true)
                for p in m.parameters { h.combine(p.name); h.combine(p.type); hash(p.annotations, &h, beansOnly: true) }
            }
        }
        return h.finalize()
    }

    /// Everything the endpoint index reads, without byte ranges.
    static func webSignature(of f: JavaFileDeclarations) -> Int {
        var h = Hasher()
        h.combine(f.packageName)
        for i in f.imports { h.combine(i) }
        for t in f.types {
            h.combine(t.qualifiedName); h.combine(t.kind); h.combine(t.modifiers.rawValue)
            hash(t.annotations, &h); h.combine(t.superclass); h.combine(t.interfaces)
            for e in t.annotationElements { h.combine(e.name); hash(e.annotations, &h); h.combine(e.defaultValue) }
            for fl in t.fields { h.combine(fl.name); h.combine(fl.type); h.combine(fl.modifiers.rawValue); hash(fl.annotations, &h) }
            for m in t.methods {
                h.combine(m.name); h.combine(m.returnType); h.combine(m.modifiers.rawValue); h.combine(m.isConstructor)
                hash(m.annotations, &h)
                for p in m.parameters { h.combine(p.name); h.combine(p.type); hash(p.annotations, &h) }
            }
        }
        return h.finalize()
    }

    private static func hash(_ annotations: [JavaAnnotationUse], _ h: inout Hasher, beansOnly: Bool = false) {
        for a in annotations {
            if beansOnly, SpringWebAnnotations.webOnly.contains(a.simpleName) { continue }
            h.combine(a.name)
            for key in a.arguments.keys.sorted() { h.combine(key); h.combine(a.arguments[key]) }
        }
    }
}

// MARK: - Endpoints

extension SpringProjectModel {
    /// The HTTP endpoints of every application context, rebuilt only when something they depend on changed. A controller whose
    /// files did not change is not read again, so a method-body edit elsewhere costs a lookup per controller, not an extraction.
    public func endpointIndexes() -> [SpringEndpointIndex] {
        if let cachedEndpointIndexes { return cachedEndpointIndexes }
        let resolver = SpringModuleResolver(modules: modules)
        let built = contexts().map { buildEndpointIndex($0, resolver: resolver) }
        cachedEndpointIndexes = built
        return built
    }

    public func endpointIndex(contextID: String) -> SpringEndpointIndex? { endpointIndexes().first { $0.contextID == contextID } }

    /// Indexes of the applications whose sources include `url`.
    public func endpointIndexes(containing url: URL) -> [SpringEndpointIndex] {
        let ids = Set(contexts(containing: url).map(\.id))
        return endpointIndexes().filter { ids.contains($0.contextID) }
    }

    func touchEndpoints(_ url: URL) {
        fileEpochs[url, default: 0] += 1
        cachedEndpointIndexes = nil
        endpointRevision += 1
    }

    private func isFresh(_ epochs: [URL: Int]) -> Bool { epochs.allSatisfy { fileEpochs[$0.key, default: 0] == $0.value } }
    private func epochs(of urls: Set<URL>) -> [URL: Int] { Dictionary(uniqueKeysWithValues: urls.map { ($0, fileEpochs[$0, default: 0]) }) }

    private func buildEndpointIndex(_ context: SpringApplicationContext, resolver: SpringModuleResolver) -> SpringEndpointIndex {
        let model = context.model
        let features = modules.first { $0.projectPath == context.moduleID }?.features ?? []
        var extractor: SpringEndpointExtractor?
        func ensureExtractor() -> SpringEndpointExtractor {
            if let extractor { return extractor }
            let scoped = files.filter { context.fileURLs.contains($0.key) }
            let made = SpringEndpointExtractor(builder: SpringModelBuilder(files: scoped, activeProfiles: profiles))
            extractor = made
            return made
        }

        // Exception handlers of `@ControllerAdvice` beans.
        var advice: [(refs: [SpringExceptionHandlerRef], selector: SpringEndpointExtractor.AdviceSelector)] = []
        for bean in model.beans where bean.stereotypes.contains(.controllerAdvice) {
            let key = context.id + "|" + bean.type.name
            if let c = adviceCache[key], isFresh(c.epochs) { advice.append((c.refs, c.selector)); continue }
            guard let found = ensureExtractor().adviceHandlers(advice: bean.type.name) else { continue }
            adviceCache[key] = CachedAdvice(refs: found.refs, selector: found.selector, epochs: epochs(of: found.touched))
            endpointFiles.formUnion(found.touched)
            advice.append((found.refs, found.selector))
        }

        var endpoints: [SpringEndpoint] = []
        var diagnostics: [SpringDiagnostic] = []
        for bean in model.beans {
            guard case .stereotype = bean.origin else { continue }
            if !(bean.stereotypes.contains(.controller) || bean.stereotypes.contains(.restController)) {
                // A `@Component` with its own `@RequestMapping` is a handler too.
                let own = files[bean.location.url]?.types.first { $0.qualifiedName == bean.type.name }
                guard own?.annotations.contains(where: { $0.simpleName.hasSuffix("Mapping") }) == true else { continue }
            }
            let key = context.id + "|" + bean.type.name
            let extraction: SpringControllerExtraction
            if let c = extractionCache[key], isFresh(c.epochs) {
                extraction = c.extraction
            } else {
                guard let fresh = ensureExtractor().extract(controller: bean.type.name, isRest: bean.stereotypes.contains(.restController)) else { continue }
                extractionCount += 1
                extraction = fresh
                extractionCache[key] = CachedExtraction(extraction: fresh, epochs: epochs(of: fresh.touched))
                endpointFiles.formUnion(fresh.touched)
            }
            diagnostics += extraction.diagnostics
            let globalStack: SpringWebStack? = features.contains(.mvc) ? .mvc : features.contains(.webflux) ? .webflux : nil
            // Everything that depends on the controller and the context (not on the endpoint) is worked out once per controller.
            let module = extraction.endpoints.first.flatMap { resolver.owner(of: $0.controllerLocation.url) }
            var handlers = extraction.handlers
            for a in advice {
                switch a.selector.admits(controller: bean.type.name) {
                case .yes: handlers += a.refs
                case .maybe: handlers += a.refs.map { r in
                    if case .advice(let n) = r.scope { return SpringExceptionHandlerRef(method: r.method, owner: r.owner, exceptions: r.exceptions, scope: .adviceMaybe(n), location: r.location) }
                    return r }
                case .no: break
                }
            }
            let prefix = context.id + "|"
            for var e in extraction.endpoints {
                e.contextID = context.id
                e.id = SpringEndpointID(raw: prefix + e.id.raw)
                e.module = module
                e.certainty = bean.certainty
                if let globalStack { e.stack = globalStack }
                e.exceptionHandlers = handlers
                endpoints.append(e)
            }
        }
        return SpringEndpointIndex(contextID: context.id, endpoints: endpoints, extractionDiagnostics: diagnostics)
    }
}

/// One Spring Boot application's view of the code: the beans it actually registers (component scan, `@Import`),
/// resolved only against that application's own sources, so two applications that share modules never mix their beans.
public struct SpringApplicationContext: Sendable, Identifiable {
    /// The entry class's qualified name, or `default` when the project has no `@SpringBootApplication` class.
    public let id: String
    public let name: String
    public let entry: SpringApplicationEntry?
    /// The entry class's module (project path), when the build model is known.
    public let moduleID: String?
    /// Every module whose sources this context can see: the entry module and its project dependencies.
    public let moduleIDs: [String]
    /// Packages scanned (`@SpringBootApplication` / `@ComponentScan`), and classes added by `@Import`.
    public let scanPackages: [String]
    public let importedTypes: [String]
    public let fileURLs: Set<URL>
    public let model: SpringModel
}
