import Foundation

/// One JVM option the run configuration form offers as a checkbox: what it adds to the VM options
/// text, what it replaces, and the Java versions that understand it.
public struct JavaVMOption: Identifiable, Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case modules
        case memory
        case garbageCollector
        case diagnostics
        case system

        public var title: String {
            switch self {
            case .modules: return "Modules and language"
            case .memory: return "Memory"
            case .garbageCollector: return "Garbage collector"
            case .diagnostics: return "Diagnostics"
            case .system: return "System and startup"
            }
        }
    }

    public let id: String
    public let category: Category
    public let title: String
    /// The tokens this option puts in the text, in order: `["--add-modules", "jdk.incubator.vector"]`.
    public let arguments: [String]
    public let summary: String
    /// The first Java feature release that accepts it; an older JDK refuses to start with it.
    public let minimumFeatureVersion: Int?
    /// Tokens this option takes the place of: exact, or a prefix when the entry ends with `*`.
    /// Adding `-Xmx2g` removes `-Xmx512m`; adding ZGC removes G1.
    public let replaces: [String]

    /// The option as it is written in the text.
    public var text: String { JavaCommandLine.join(arguments) }
}

/// The curated list behind the VM options picker, and the text edits that turn an option on and off.
/// Everything here is pure: the form passes the field's text in and takes the new text back, and
/// the arguments are still split by ``JavaCommandLine/split(_:)`` when the program is launched.
public enum JavaVMOptions {
    public static let all: [JavaVMOption] = modules + memory + garbageCollectors + diagnostics + system

    public static func options(in category: JavaVMOption.Category) -> [JavaVMOption] {
        all.filter { $0.category == category }
    }

    // MARK: - Reading and editing the text

    /// Whether every token of `option` is in `text`, as the separate tokens or, for a `--flag value`
    /// option, as `--flag=value`.
    public static func isEnabled(_ option: JavaVMOption, in text: String) -> Bool {
        match(option, in: JavaCommandLine.split(text)) != nil
    }

    /// `text` with `option` added at the end, after taking out what it replaces. Text that needs no
    /// removal is kept as written; an option already present is not added twice.
    public static func adding(_ option: JavaVMOption, to text: String) -> String {
        var tokens = JavaCommandLine.split(text)
        // The option's own tokens stay where they are, so enabling what is on does not move it.
        let kept = tokens.filter { token in
            option.arguments.contains(token) || !option.replaces.contains { matches(token, pattern: $0) }
        }
        let removedAny = kept.count != tokens.count
        tokens = kept
        if match(option, in: tokens) != nil {
            return removedAny ? JavaCommandLine.join(tokens) : text
        }
        if removedAny { return JavaCommandLine.join(tokens + option.arguments) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? option.text : trimmed + " " + option.text
    }

    /// `text` without `option`; unchanged when it is not there.
    public static func removing(_ option: JavaVMOption, from text: String) -> String {
        var tokens = JavaCommandLine.split(text)
        guard let range = match(option, in: tokens) else { return text }
        tokens.removeSubrange(range)
        return JavaCommandLine.join(tokens)
    }

    /// Whether a JDK of `featureVersion` accepts `option`. An unknown version accepts everything.
    public static func isAvailable(_ option: JavaVMOption, featureVersion: Int?) -> Bool {
        guard let minimum = option.minimumFeatureVersion, let featureVersion else { return true }
        return featureVersion >= minimum
    }

    // MARK: - Matching

    private static func matches(_ token: String, pattern: String) -> Bool {
        pattern.hasSuffix("*") ? token.hasPrefix(String(pattern.dropLast())) : token == pattern
    }

    /// The token range an enabled `option` occupies in `tokens`.
    private static func match(_ option: JavaVMOption, in tokens: [String]) -> Range<Int>? {
        let arguments = option.arguments
        guard !arguments.isEmpty, tokens.count >= 1 else { return nil }
        if arguments.count > 1, tokens.count >= arguments.count {
            for start in 0...(tokens.count - arguments.count)
            where Array(tokens[start..<(start + arguments.count)]) == arguments {
                return start..<(start + arguments.count)
            }
        }
        if arguments.count == 2, arguments[0].hasPrefix("--") {
            let joined = arguments[0] + "=" + arguments[1]
            if let index = tokens.firstIndex(of: joined) { return index..<(index + 1) }
        }
        if arguments.count == 1, let index = tokens.firstIndex(of: arguments[0]) { return index..<(index + 1) }
        return nil
    }

    // MARK: - The list

    private static let modules: [JavaVMOption] = [
        JavaVMOption(
            id: "vector-api", category: .modules, title: "Vector API",
            arguments: ["--add-modules", "jdk.incubator.vector"],
            summary: "The incubating SIMD module. The compiler needs it too: add the same flag to the build's compiler arguments.",
            minimumFeatureVersion: 16, replaces: []
        ),
        JavaVMOption(
            id: "enable-preview", category: .modules, title: "Preview features",
            arguments: ["--enable-preview"],
            summary: "Runs classes compiled with preview features of this Java release.",
            minimumFeatureVersion: 12, replaces: []
        ),
        JavaVMOption(
            id: "native-access", category: .modules, title: "Native access",
            arguments: ["--enable-native-access=ALL-UNNAMED"],
            summary: "Lets code on the classpath use the foreign function and memory API without a warning.",
            minimumFeatureVersion: 16, replaces: []
        ),
        JavaVMOption(
            id: "open-java-lang", category: .modules, title: "Open java.lang to reflection",
            arguments: ["--add-opens", "java.base/java.lang=ALL-UNNAMED"],
            summary: "For libraries that reach into JDK internals, which fail with InaccessibleObjectException.",
            minimumFeatureVersion: 9, replaces: []
        ),
        JavaVMOption(
            id: "open-java-util", category: .modules, title: "Open java.util to reflection",
            arguments: ["--add-opens", "java.base/java.util=ALL-UNNAMED"],
            summary: "The same for java.util, which serializers and mocking libraries often need.",
            minimumFeatureVersion: 9, replaces: []
        )
    ]

    private static let memory: [JavaVMOption] = {
        let heaps = [("512m", "512 MB"), ("1g", "1 GB"), ("2g", "2 GB"), ("4g", "4 GB")]
        let heapOptions = heaps.map { size, label in
            JavaVMOption(
                id: "heap-\(size)", category: .memory, title: "Maximum heap \(label)",
                arguments: ["-Xmx\(size)"], summary: "Largest size the heap may grow to.",
                minimumFeatureVersion: nil, replaces: ["-Xmx*"]
            )
        }
        return heapOptions + [
            JavaVMOption(
                id: "stack-4m", category: .memory, title: "Thread stack 4 MB",
                arguments: ["-Xss4m"], summary: "More room for deep recursion, at a cost per thread.",
                minimumFeatureVersion: nil, replaces: ["-Xss*"]
            ),
            JavaVMOption(
                id: "heap-dump-on-oom", category: .memory, title: "Heap dump on OutOfMemoryError",
                arguments: ["-XX:+HeapDumpOnOutOfMemoryError"],
                summary: "Writes a .hprof file to the working directory when the heap runs out.",
                minimumFeatureVersion: nil, replaces: ["-XX:-HeapDumpOnOutOfMemoryError"]
            ),
            JavaVMOption(
                id: "exit-on-oom", category: .memory, title: "Exit on OutOfMemoryError",
                arguments: ["-XX:+ExitOnOutOfMemoryError"],
                summary: "Ends the program at the first OutOfMemoryError instead of limping on.",
                minimumFeatureVersion: 8, replaces: ["-XX:-ExitOnOutOfMemoryError"]
            )
        ]
    }()

    private static let allCollectors = [
        "-XX:+UseG1GC", "-XX:+UseZGC", "-XX:+UseParallelGC", "-XX:+UseSerialGC",
        "-XX:+UseShenandoahGC", "-XX:+UseEpsilonGC", "-XX:+UseConcMarkSweepGC"
    ]

    private static let garbageCollectors: [JavaVMOption] = [
        JavaVMOption(
            id: "gc-g1", category: .garbageCollector, title: "G1",
            arguments: ["-XX:+UseG1GC"], summary: "The default on a machine with two or more cores and 1.8 GB of memory.",
            minimumFeatureVersion: nil, replaces: allCollectors
        ),
        JavaVMOption(
            id: "gc-zgc", category: .garbageCollector, title: "ZGC",
            arguments: ["-XX:+UseZGC"], summary: "Pauses of about a millisecond on large heaps, for latency-sensitive programs.",
            minimumFeatureVersion: 15, replaces: allCollectors
        ),
        JavaVMOption(
            id: "gc-parallel", category: .garbageCollector, title: "Parallel",
            arguments: ["-XX:+UseParallelGC"], summary: "Throughput first, with longer pauses. Suits batch jobs.",
            minimumFeatureVersion: nil, replaces: allCollectors
        ),
        JavaVMOption(
            id: "gc-serial", category: .garbageCollector, title: "Serial",
            arguments: ["-XX:+UseSerialGC"], summary: "One thread and the smallest footprint. Suits small programs and containers.",
            minimumFeatureVersion: nil, replaces: allCollectors
        )
    ]

    private static let diagnostics: [JavaVMOption] = [
        JavaVMOption(
            id: "assertions", category: .diagnostics, title: "Assertions",
            arguments: ["-ea"], summary: "Turns on assert statements. Off by default in a plain launch.",
            minimumFeatureVersion: nil, replaces: ["-da", "-disableassertions"]
        ),
        JavaVMOption(
            id: "gc-log", category: .diagnostics, title: "GC log",
            arguments: ["-Xlog:gc"], summary: "One line per collection on standard output.",
            minimumFeatureVersion: 9, replaces: ["-Xlog:gc"]
        ),
        JavaVMOption(
            id: "native-memory-tracking", category: .diagnostics, title: "Native memory tracking",
            arguments: ["-XX:NativeMemoryTracking=summary"],
            summary: "Counts native allocations by area. Read it with jcmd VM.native_memory.",
            minimumFeatureVersion: 8, replaces: ["-XX:NativeMemoryTracking=*"]
        )
    ]

    private static let system: [JavaVMOption] = [
        JavaVMOption(
            id: "utf8", category: .system, title: "UTF-8 default charset",
            arguments: ["-Dfile.encoding=UTF-8"], summary: "UTF-8 is already the default from Java 18.",
            minimumFeatureVersion: nil, replaces: ["-Dfile.encoding=*"]
        ),
        JavaVMOption(
            id: "headless", category: .system, title: "Headless AWT",
            arguments: ["-Djava.awt.headless=true"], summary: "Runs AWT code without a display.",
            minimumFeatureVersion: nil, replaces: ["-Djava.awt.headless=*"]
        ),
        JavaVMOption(
            id: "utc", category: .system, title: "UTC time zone",
            arguments: ["-Duser.timezone=UTC"], summary: "Makes dates the same on every machine.",
            minimumFeatureVersion: nil, replaces: ["-Duser.timezone=*"]
        ),
        JavaVMOption(
            id: "ipv4", category: .system, title: "Prefer IPv4",
            arguments: ["-Djava.net.preferIPv4Stack=true"], summary: "Avoids slow or failing connections on networks without IPv6.",
            minimumFeatureVersion: nil, replaces: ["-Djava.net.preferIPv4Stack=*"]
        ),
        JavaVMOption(
            id: "fast-start", category: .system, title: "Faster start, lower peak speed",
            arguments: ["-XX:TieredStopAtLevel=1"],
            summary: "Only the quick compiler: short programs and tests start sooner, long ones run slower.",
            minimumFeatureVersion: nil, replaces: ["-XX:TieredStopAtLevel=*"]
        )
    ]
}
