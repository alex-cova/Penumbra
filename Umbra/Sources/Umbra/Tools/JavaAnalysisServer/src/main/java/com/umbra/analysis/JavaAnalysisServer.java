package com.umbra.analysis;

import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.tree.LineMap;
import com.sun.source.tree.Tree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.SourcePositions;
import com.sun.source.util.TreePath;
import com.sun.source.util.TreeScanner;
import com.sun.source.util.Trees;

import javax.lang.model.element.Element;
import javax.lang.model.element.ElementKind;
import javax.lang.model.element.QualifiedNameable;
import javax.lang.model.type.TypeKind;
import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.FileObject;
import javax.tools.ForwardingJavaFileManager;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileManager;
import javax.tools.JavaFileObject;
import javax.tools.SimpleJavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.StandardLocation;
import javax.tools.ToolProvider;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Warm {@code javac} analysis server for Umbra. Reads JSON lines from stdin, writes JSON lines to
 * stdout — the same framing as {@code DebugAdapter} — so the editor gets real compiler errors
 * without paying cold-start {@code javac} on every keystroke.
 *
 * <p>Protocol (one JSON object per line; every request carries a numeric {@code id}):
 *
 * <pre>
 * {"id":1,"method":"configure","params":{
 *   "moduleId":"app/main",
 *   "classpath":["/…/guava.jar"], "sourcepath":["/…/src/main/java"],
 *   "release":"17", "processorPath":["/…/lombok.jar"], "options":["-Xmaxerrs","200"]}}
 * → {"id":1,"result":{"ok":true}}
 *
 * {"id":2,"method":"check","params":{
 *   "moduleId":"app/main", "file":"/…/Foo.java", "text":"…",
 *   "overlays":[{"file":"/…/Bar.java","text":"…"}]}}
 * → {"id":2,"result":{"diagnostics":[{
 *     "key":"compiler.err.cant.resolve.location",
 *     "severity":"error", "start":123, "end":128, "line":4, "column":11,
 *     "file":"/…/Foo.java", "message":"cannot find symbol…"}]}}
 *
 * {"id":3,"method":"attribute","params":{
 *   "moduleId":"app/main", "file":"/…/Foo.java", "text":"…", "positions":[120,188]}}
 * → {"id":3,"result":{"symbols":[{
 *     "position":120, "kind":"method", "name":"sort",
 *     "qualified":"java.util.Collections.sort",
 *     "declarationFile":"/…/Collections.java",
 *     "declarationStartLine":240, "declarationEndLine":268}]}}
 *
 * {"id":4,"method":"cancel","params":{"id":2}} → {"id":4,"result":{"ok":true}}
 * {"id":5,"method":"shutdown","params":{}}     → {"id":5,"result":{"ok":true}} (then exits)
 * </pre>
 *
 * <p>{@code attribute} is the symbol oracle. It attributes {@code file} and resolves each
 * UTF-16 offset with {@link Trees#getElement}: the smallest tree that covers the offset.
 * {@code kind} is {@link ElementKind} in lower case, {@code name} is the simple name a
 * completion list would show (the enclosing type's name for a constructor), and the
 * declaration fields are present only when that symbol was compiled from source. A position
 * with no resolvable symbol is absent from {@code symbols}. Offsets are the same UTF-16
 * code units as {@code check}.
 *
 * <p>{@code key} is {@link Diagnostic#getCode} (e.g. {@code compiler.err.cant.resolve}),
 * {@code start}/{@code end} are UTF-16 offsets into the buffer text the diagnostic is about
 * (absent when the compiler reports no position), and {@code line}/{@code column} are the
 * 1-based line and 0-based column of the diagnostic's preferred position — the same line the
 * CLI prints, which is not always the line {@code start} sits on (e.g. {@code missing.ret.stmt}
 * spans the body but points at its end). {@code file} is the path {@code javac} attributed the
 * diagnostic to — diagnostics about other files are included, and the client filters to the
 * file it asked about.
 *
 * <p>Lifecycle notes:
 * <ul>
 *   <li>One {@link StandardJavaFileManager} per {@code moduleId} is cached, so classpath jars
 *       stay open across requests. A fresh {@link JavacTask} is created per {@code check}.</li>
 *   <li>The checked file and every overlay are passed as explicit in-memory compilation units,
 *       so open buffers shadow what is on disk. References between open buffers resolve
 *       because all of them are units of the same task.</li>
 *   <li>{@code check} runs on a worker thread; {@code cancel} suppresses the pending response
 *       (an in-flight compilation itself is not aborted) and {@code shutdown} stays responsive.</li>
 *   <li>Only public {@code javax.tools} / {@code com.sun.source} APIs are used, so no
 *       {@code --add-exports} is needed and the server runs on any JDK 17+.</li>
 * </ul>
 */
public final class JavaAnalysisServer {
    private final BufferedReader in =
            new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    private final PrintWriter out =
            new PrintWriter(new java.io.OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);

    /** One worker: checks run in request order while the reader loop stays responsive. */
    private final ExecutorService checks = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "analysis-check");
        t.setDaemon(true);
        return t;
    });

    private final JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
    /** Module configurations by id; StandardJavaFileManagers are cached alongside them. */
    private final Map<String, Module> modules = new ConcurrentHashMap<>();
    /** Check ids whose response must be suppressed. */
    private final Set<Long> cancelled = ConcurrentHashMap.newKeySet();
    private final Object writeLock = new Object();

    private static final class Module {
        final List<Path> classpath;
        final List<Path> sourcepath;
        final String release;
        final List<Path> processorPath;
        final List<String> options;
        StandardJavaFileManager files;

        Module(List<Path> classpath, List<Path> sourcepath, String release,
               List<Path> processorPath, List<String> options) {
            this.classpath = classpath;
            this.sourcepath = sourcepath;
            this.release = release;
            this.processorPath = processorPath;
            this.options = options;
        }
    }

    /** A buffer held in memory but addressed by its real file URI, so diagnostics map back. */
    private static final class MemorySource extends SimpleJavaFileObject {
        private final String text;

        MemorySource(Path file, String text) {
            super(file.toUri(), Kind.SOURCE);
            this.text = text;
        }

        @Override
        public CharSequence getCharContent(boolean ignoreEncodingErrors) {
            return text;
        }
    }

    /**
     * Drops class files: the server runs the whole pipeline (parse, enter, process
     * annotations, attribute, flow) so positions and annotation-processor behaviour match a
     * real build, but it never emits.
     */
    private static final class DiscardingOutputs extends ForwardingJavaFileManager<StandardJavaFileManager> {
        DiscardingOutputs(StandardJavaFileManager files) {
            super(files);
        }

        @Override
        public JavaFileObject getJavaFileForOutput(
                JavaFileManager.Location location, String className, JavaFileObject.Kind kind,
                FileObject sibling) {
            return new SimpleJavaFileObject(
                    URI.create("mem:///" + className.replace('.', '/') + kind.extension), kind) {
                @Override
                public OutputStream openOutputStream() {
                    return OutputStream.nullOutputStream();
                }
            };
        }
    }

    public static void main(String[] args) throws Exception {
        if (ToolProvider.getSystemJavaCompiler() == null) {
            System.err.println("JavaAnalysisServer needs a JDK (no compiler on the classpath)");
            System.exit(2);
        }
        new JavaAnalysisServer().run();
    }

    private void run() throws Exception {
        String line;
        while ((line = in.readLine()) != null) {
            Map<String, Object> request;
            try {
                request = Json.parseObject(line);
            } catch (IllegalArgumentException malformed) {
                respond(null, null, "malformed JSON: " + malformed.getMessage());
                continue;
            }
            long id = toLong(request.get("id"), -1);
            String method = String.valueOf(request.get("method"));
            @SuppressWarnings("unchecked")
            Map<String, Object> params = request.get("params") instanceof Map<?, ?> map
                    ? (Map<String, Object>) map : Map.of();
            switch (method) {
                case "configure" -> handleConfigure(id, params);
                case "check" -> handleCheck(id, params);
                case "attribute" -> handleAttribute(id, params);
                case "cancel" -> {
                    cancelled.add(toLong(params.get("id"), -1));
                    respond(id, Map.of("ok", true), null);
                }
                case "shutdown" -> {
                    respond(id, Map.of("ok", true), null);
                    // Drain submitted checks first: the client awaits each check's response,
                    // so exiting early would lose them. A hung check still exits via the timeout.
                    checks.shutdown();
                    try {
                        if (!checks.awaitTermination(30, java.util.concurrent.TimeUnit.SECONDS)) {
                            checks.shutdownNow();
                        }
                    } catch (InterruptedException interrupted) {
                        checks.shutdownNow();
                        Thread.currentThread().interrupt();
                    }
                    closeManagers();
                    return;
                }
                default -> respond(id, null, "unknown method: " + method);
            }
        }
    }

    // MARK: - configure

    private void handleConfigure(long id, Map<String, Object> params) {
        String moduleId = string(params.get("moduleId"), "");
        if (moduleId.isEmpty()) {
            respond(id, null, "configure needs moduleId");
            return;
        }
        Module module = new Module(
                toPaths(params.get("classpath")),
                toPaths(params.get("sourcepath")),
                string(params.get("release"), null),
                toPaths(params.get("processorPath")),
                toStrings(params.get("options")));
        Module previous = modules.put(moduleId, module);
        if (previous != null && previous.files != null) {
            closeQuietly(previous.files);
        }
        respond(id, Map.of("ok", true), null);
    }

    // MARK: - check

    private void handleCheck(long id, Map<String, Object> params) {
        String moduleId = string(params.get("moduleId"), "");
        String file = string(params.get("file"), "");
        String text = string(params.get("text"), null);
        if (moduleId.isEmpty() || file.isEmpty() || text == null) {
            respond(id, null, "check needs moduleId, file and text");
            return;
        }
        List<MemorySource> overlays = new ArrayList<>();
        Object rawOverlays = params.get("overlays");
        if (rawOverlays instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Map<?, ?> overlay) {
                    String overlayFile = string(overlay.get("file"), "");
                    String overlayText = string(overlay.get("text"), null);
                    if (!overlayFile.isEmpty() && overlayText != null
                            && !overlayFile.equals(file)) {
                        overlays.add(new MemorySource(Path.of(overlayFile), overlayText));
                    }
                }
            }
        }
        Module module = modules.get(moduleId);
        if (module == null) {
            respond(id, null, "unknown moduleId (configure first): " + moduleId);
            return;
        }
        MemorySource main = new MemorySource(Path.of(file), text);
        checks.submit(() -> {
            if (cancelled.remove(id)) {
                respond(id, null, "cancelled");
                return;
            }
            try {
                respond(id, Map.of("diagnostics", check(module, main, overlays)), null);
            } catch (IllegalArgumentException badOptions) {
                // Unsupported --release, bad paths: the client falls back to the CLI path.
                respond(id, null, badOptions.getMessage());
            } catch (Exception failure) {
                respond(id, null, "check failed: " + failure);
            }
        });
    }

    private List<Object> check(Module module, MemorySource main, List<MemorySource> overlays)
            throws Exception {
        List<JavaFileObject> units = new ArrayList<>();
        units.add(main);
        units.addAll(overlays);
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        // The full pipeline, like a real build: positions and processor behaviour match CLI
        // javac. Class files go nowhere (see DiscardingOutputs).
        task(module, units, diagnostics).call();

        List<Object> encoded = new ArrayList<>();
        for (Diagnostic<? extends JavaFileObject> diagnostic : diagnostics.getDiagnostics()) {
            encoded.add(encode(diagnostic));
        }
        return encoded;
    }

    // MARK: - attribute

    private void handleAttribute(long id, Map<String, Object> params) {
        String moduleId = string(params.get("moduleId"), "");
        String file = string(params.get("file"), "");
        String text = string(params.get("text"), null);
        if (moduleId.isEmpty() || file.isEmpty() || text == null) {
            respond(id, null, "attribute needs moduleId, file and text");
            return;
        }
        Module module = modules.get(moduleId);
        if (module == null) {
            respond(id, null, "unknown moduleId (configure first): " + moduleId);
            return;
        }
        List<Long> positions = toLongs(params.get("positions"));
        if (positions.size() > 200) {
            positions = positions.subList(0, 200);
        }
        MemorySource main = new MemorySource(Path.of(file), text);
        List<Long> queried = positions;
        checks.submit(() -> {
            if (cancelled.remove(id)) {
                respond(id, null, "cancelled");
                return;
            }
            try {
                respond(id, Map.of("symbols", attribute(module, main, queried)), null);
            } catch (IllegalArgumentException badOptions) {
                respond(id, null, badOptions.getMessage());
            } catch (Exception failure) {
                respond(id, null, "attribute failed: " + failure);
            }
        });
    }

    /**
     * The symbol at each offset, after attribution. One position that the compiler cannot
     * attribute is omitted; it does not fail the file.
     */
    private List<Object> attribute(Module module, MemorySource main, List<Long> positions) throws Exception {
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        JavacTask javac = task(module, List.<JavaFileObject>of(main), diagnostics);
        List<CompilationUnitTree> parsed = new ArrayList<>();
        for (CompilationUnitTree unit : javac.parse()) parsed.add(unit);
        javac.analyze();
        if (parsed.isEmpty()) return List.of();
        CompilationUnitTree unit = parsed.get(0);
        Trees trees = Trees.instance(javac);
        SourcePositions sourcePositions = trees.getSourcePositions();

        List<Tree> leaves = new ArrayList<>();
        new TreeScanner<Void, Void>() {
            @Override
            public Void scan(Tree tree, Void unused) {
                if (tree == null) return null;
                long start = sourcePositions.getStartPosition(unit, tree);
                long end = sourcePositions.getEndPosition(unit, tree);
                if (start != Diagnostic.NOPOS && end != Diagnostic.NOPOS && start < end) {
                    leaves.add(tree);
                }
                return super.scan(tree, unused);
            }
        }.scan(unit, null);

        List<Object> symbols = new ArrayList<>();
        for (long position : positions) {
            Tree best = null;
            long bestSpan = Long.MAX_VALUE;
            for (Tree tree : leaves) {
                long start = sourcePositions.getStartPosition(unit, tree);
                long end = sourcePositions.getEndPosition(unit, tree);
                long span = end - start;
                // A later tree of the same span is nested inside the earlier one.
                if (start <= position && position < end && span <= bestSpan) {
                    best = tree;
                    bestSpan = span;
                }
            }
            if (best == null) continue;
            try {
                Map<String, Object> encoded = encodeSymbol(trees, sourcePositions, unit, best, position);
                if (encoded != null) symbols.add(encoded);
            } catch (RuntimeException unresolved) {
                // One offset the compiler cannot attribute.
            }
        }
        return symbols;
    }

    private static Map<String, Object> encodeSymbol(
            Trees trees, SourcePositions sourcePositions, CompilationUnitTree unit, Tree leaf, long position) {
        TreePath path = TreePath.getPath(unit, leaf);
        if (path == null) return null;
        Element element = trees.getElement(path);
        if (element == null || element.asType().getKind() == TypeKind.ERROR) return null;
        String name = element.getSimpleName().toString();
        if (element.getKind() == ElementKind.CONSTRUCTOR) {
            Element owner = element.getEnclosingElement();
            name = owner == null ? "" : owner.getSimpleName().toString();
        }
        if (name.isEmpty() || "<init>".equals(name)) return null;

        Map<String, Object> encoded = new LinkedHashMap<>();
        encoded.put("position", position);
        encoded.put("kind", element.getKind().name().toLowerCase(Locale.ROOT));
        encoded.put("name", name);
        encoded.put("qualified", qualifiedName(element));

        TreePath declaration = trees.getPath(element);
        if (declaration == null) return encoded;
        CompilationUnitTree declarationUnit = declaration.getCompilationUnit();
        long start = sourcePositions.getStartPosition(declarationUnit, declaration.getLeaf());
        long end = sourcePositions.getEndPosition(declarationUnit, declaration.getLeaf());
        if (start == Diagnostic.NOPOS || end == Diagnostic.NOPOS || end <= start) return encoded;
        URI uri = declarationUnit.getSourceFile().toUri();
        if (!"file".equals(uri.getScheme())) return encoded;
        LineMap lines = declarationUnit.getLineMap();
        encoded.put("declarationFile", Path.of(uri).toString());
        encoded.put("declarationStartLine", lines.getLineNumber(start));
        encoded.put("declarationEndLine", lines.getLineNumber(end - 1));
        return encoded;
    }

    private static String qualifiedName(Element element) {
        if (element instanceof QualifiedNameable named) {
            String qualified = named.getQualifiedName().toString();
            if (!qualified.isEmpty()) return qualified;
        }
        String simple = element.getSimpleName().toString();
        Element owner = element.getEnclosingElement();
        if (owner instanceof QualifiedNameable named) {
            String ownerName = named.getQualifiedName().toString();
            if (!ownerName.isEmpty()) return ownerName + "." + simple;
        }
        return simple;
    }

    /** The file manager cached for the module, and a task over {@code units} that emits nothing. */
    private JavacTask task(
            Module module, List<JavaFileObject> units, DiagnosticCollector<JavaFileObject> diagnostics)
            throws Exception {
        StandardJavaFileManager files;
        synchronized (module) {
            if (module.files == null) {
                module.files = compiler.getStandardFileManager(null, null, StandardCharsets.UTF_8);
                if (!module.classpath.isEmpty()) {
                    module.files.setLocationFromPaths(StandardLocation.CLASS_PATH, module.classpath);
                }
                if (!module.sourcepath.isEmpty()) {
                    module.files.setLocationFromPaths(StandardLocation.SOURCE_PATH, module.sourcepath);
                }
                if (!module.processorPath.isEmpty()) {
                    module.files.setLocationFromPaths(
                            StandardLocation.ANNOTATION_PROCESSOR_PATH, module.processorPath);
                }
            }
            files = module.files;
        }

        List<String> options = new ArrayList<>();
        options.add("-Xmaxerrs");
        options.add("200");
        options.add("-Xmaxwarns");
        options.add("200");
        if (module.release != null && !module.release.isEmpty()) {
            options.add("--release");
            options.add(module.release);
        }
        if (module.processorPath.isEmpty()) {
            options.add("-proc:none");
        }
        options.addAll(module.options);
        return (JavacTask) compiler.getTask(
                null, new DiscardingOutputs(files), diagnostics, options, null, units);
    }

    private static Map<String, Object> encode(Diagnostic<? extends JavaFileObject> diagnostic) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("key", diagnostic.getCode());
        out.put("severity", diagnostic.getKind() == Diagnostic.Kind.ERROR ? "error" : "warning");
        if (diagnostic.getStartPosition() != Diagnostic.NOPOS) {
            out.put("start", diagnostic.getStartPosition());
        }
        if (diagnostic.getEndPosition() != Diagnostic.NOPOS) {
            out.put("end", diagnostic.getEndPosition());
        }
        if (diagnostic.getLineNumber() != Diagnostic.NOPOS) {
            out.put("line", diagnostic.getLineNumber());
        }
        if (diagnostic.getColumnNumber() != Diagnostic.NOPOS) {
            // getColumnNumber is 1-based; the CLI caret (and JavacOutputParser) is 0-based.
            out.put("column", diagnostic.getColumnNumber() - 1);
        }
        JavaFileObject source = diagnostic.getSource();
        if (source != null) {
            URI uri = source.toUri();
            // MemorySource carries the real file:// URI; anything else keeps its raw form.
            out.put("file", "file".equals(uri.getScheme()) ? Path.of(uri).toString() : uri.toString());
        }
        try {
            out.put("message", diagnostic.getMessage(Locale.ENGLISH));
        } catch (Exception unreadable) {
            out.put("message", diagnostic.toString());
        }
        return out;
    }

    // MARK: - JSON plumbing

    private void respond(Long id, Object result, String error) {
        Map<String, Object> response = new LinkedHashMap<>();
        // A malformed request has no id to echo; a negative id never occurs otherwise.
        response.put("id", id == null || id < 0 ? null : id);
        if (error != null) {
            response.put("error", Map.of("message", error));
        } else {
            response.put("result", result);
        }
        synchronized (writeLock) {
            out.println(Json.stringify(response));
        }
    }

    private void closeManagers() {
        for (Module module : modules.values()) {
            synchronized (module) {
                if (module.files != null) closeQuietly(module.files);
                module.files = null;
            }
        }
    }

    private static void closeQuietly(JavaFileManager files) {
        try {
            files.close();
        } catch (Exception ignored) {
            // Best effort on shutdown.
        }
    }

    private static long toLong(Object value, long fallback) {
        if (value instanceof Number number) return number.longValue();
        try {
            return Long.parseLong(String.valueOf(value));
        } catch (NumberFormatException notANumber) {
            return fallback;
        }
    }

    private static String string(Object value, String fallback) {
        return value instanceof String s ? s : fallback;
    }

    private static List<Path> toPaths(Object value) {
        List<Path> paths = new ArrayList<>();
        if (value instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof String s && !s.isEmpty()) paths.add(Path.of(s));
            }
        }
        return paths;
    }

    private static List<Long> toLongs(Object value) {
        List<Long> numbers = new ArrayList<>();
        if (value instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof Number number) numbers.add(number.longValue());
            }
        }
        return numbers;
    }

    private static List<String> toStrings(Object value) {
        List<String> strings = new ArrayList<>();
        if (value instanceof List<?> list) {
            for (Object item : list) {
                if (item instanceof String s) strings.add(s);
            }
        }
        return strings;
    }
}
