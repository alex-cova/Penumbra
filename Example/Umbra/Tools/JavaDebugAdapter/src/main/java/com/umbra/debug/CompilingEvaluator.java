package com.umbra.debug;

import com.sun.jdi.*;

import javax.lang.model.SourceVersion;
import javax.tools.*;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The second evaluation tier: compiles an expression the interpreter cannot run (a lambda, a
 * method reference, a stream pipeline) into a small class and runs it in the target.
 *
 * <p>The class has one static method whose parameters are the frame's visible locals and
 * {@code __self} (the frame's {@code this}); an unqualified field or method of {@code this} that
 * javac cannot find is rewritten to {@code __self.name} and compiled again. The class is compiled
 * with the JDK the adapter runs on, against the program's classpath and the source file's imports,
 * then defined through JDI in the frame's own class loader and package (so package-private types
 * and members work; private members of other classes do not), and invoked.
 *
 * <p>Compiled classes are cached per expression, location and local variable types, so a
 * condition that needs this tier compiles once, not on every hit.
 */
final class CompilingEvaluator implements Evaluator.Compiler {
    /** Shared by every evaluation of a session: compiled classes and the program's classpath. */
    static final class Cache {
        private final Map<String, ClassType> classes = new HashMap<>();
        private int counter;
        private String classpath;

        synchronized ClassType get(String key) {
            return classes.get(key);
        }

        synchronized void put(String key, ClassType type) {
            classes.put(key, type);
        }

        synchronized String nextName() {
            return "__UmbraEval" + (++counter);
        }

        synchronized void setClasspath(String classpath) {
            this.classpath = classpath == null || classpath.isBlank() ? null : classpath;
        }

        synchronized String classpath() {
            return classpath;
        }

        synchronized void clear() {
            classes.clear();
        }
    }

    private static final int MAX_ATTEMPTS = 5;
    private static final Pattern MISSING_SYMBOL = Pattern.compile("symbol:\\s+(variable|method)\\s+([A-Za-z_$][A-Za-z0-9_$]*)");

    private final VirtualMachine vm;
    private final Cache cache;
    private final List<String> imports;
    private final Runnable beforeInvoke;
    private final Runnable afterInvoke;

    CompilingEvaluator(VirtualMachine vm, Cache cache, List<String> imports, Runnable beforeInvoke, Runnable afterInvoke) {
        this.vm = vm;
        this.cache = cache;
        this.imports = imports == null ? List.of() : imports;
        this.beforeInvoke = beforeInvoke;
        this.afterInvoke = afterInvoke;
    }

    private record Parameter(String name, String type, Supplier<Value> value) {}

    @Override
    public Value evaluate(String expression, ThreadReference thread, int frameIndex) {
        StackFrame frame = frame(thread, frameIndex);
        Location location = frame.location();
        ReferenceType declaring = location.declaringType();
        List<Parameter> parameters = parameters(thread, frameIndex, frame, declaring);
        String packageName = packageOf(declaring);
        boolean restricted = packageName.startsWith("java.") || packageName.equals("java");
        if (restricted) packageName = "";

        StringBuilder signature = new StringBuilder();
        for (Parameter parameter : parameters) signature.append(parameter.type).append(' ').append(parameter.name).append(',');
        String key = location.declaringType().name() + "#" + location.method().name() + ":" + location.lineNumber()
                + "|" + signature + "|" + String.join(";", imports) + "|" + expression;
        ClassType compiled = cache.get(key);
        if (compiled == null) {
            ClassLoaderReference loader = restricted ? null : declaring.classLoader();
            compiled = compileAndDefine(expression, packageName, parameters, declaring, loader, thread);
            cache.put(key, compiled);
        }
        ClassType evalClass = compiled;
        Method method = evalClass.methodsByName("eval").get(0);
        List<Value> args = new ArrayList<>();
        for (Parameter parameter : parameters) args.add(parameter.value.get());
        return invoke("the expression", () -> evalClass.invokeMethod(thread, method, args, ClassType.INVOKE_SINGLE_THREADED));
    }

    private static StackFrame frame(ThreadReference thread, int frameIndex) {
        try {
            return thread.frame(frameIndex);
        } catch (IncompatibleThreadStateException e) {
            throw new Evaluator.EvaluationException("The program is not paused.");
        } catch (IndexOutOfBoundsException e) {
            throw new Evaluator.EvaluationException("There is no such stack frame.");
        }
    }

    /** The frame's locals and `this`, as parameters. Values are read again at call time. */
    private List<Parameter> parameters(ThreadReference thread, int frameIndex, StackFrame frame, ReferenceType declaring) {
        List<Parameter> parameters = new ArrayList<>();
        try {
            for (LocalVariable local : frame.visibleVariables()) {
                String type = sourceType(local.genericSignature(), local.typeName());
                parameters.add(new Parameter(local.name(), type, () -> {
                    StackFrame current = frame(thread, frameIndex);
                    return current.getValue(local);
                }));
            }
        } catch (AbsentInformationException ignored) {
            // No locals: `this` and statics still work.
        }
        if (frame.thisObject() != null) {
            String type = nameable(declaring.name()) ? sourceName(declaring.name()) : "Object";
            parameters.add(new Parameter("__self", type, () -> frame(thread, frameIndex).thisObject()));
        }
        return parameters;
    }

    private ClassType compileAndDefine(String expression, String packageName, List<Parameter> parameters,
                                       ReferenceType declaring, ClassLoaderReference loader, ThreadReference thread) {
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        if (compiler == null) throw new Evaluator.EvaluationException("This expression needs a JDK with javac to evaluate.");
        String className = cache.nextName();
        String qualified = packageName.isEmpty() ? className : packageName + "." + className;
        String body = expression.trim();
        boolean asStatement = false;
        Set<String> rewritten = new HashSet<>();
        String lastErrors = "";
        for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
            String source = source(packageName, className, parameters, body, asStatement);
            Map<String, byte[]> classes = new HashMap<>();
            DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
            boolean ok = compile(compiler, qualified, source, classes, diagnostics, thread);
            if (ok) return define(qualified, classes, loader, thread);
            List<String> errors = new ArrayList<>();
            boolean changed = false;
            for (Diagnostic<? extends JavaFileObject> diagnostic : diagnostics.getDiagnostics()) {
                if (diagnostic.getKind() != Diagnostic.Kind.ERROR) continue;
                String message = diagnostic.getMessage(Locale.ROOT);
                errors.add(message.lines().findFirst().orElse(message));
                if (!asStatement && message.contains("'void' type not allowed")) {
                    asStatement = true;
                    changed = true;
                }
                Matcher missing = MISSING_SYMBOL.matcher(message);
                if (missing.find()) {
                    String name = missing.group(2);
                    String qualifier = qualifierFor(name, missing.group(1).equals("method"), declaring);
                    if (qualifier != null && rewritten.add(name)) {
                        body = qualify(body, name, qualifier);
                        changed = true;
                    }
                }
            }
            lastErrors = String.join(" ", new LinkedHashSet<>(errors));
            if (!changed) break;
        }
        throw new Evaluator.EvaluationException("Cannot compile the expression: " + lastErrors);
    }

    private String source(String packageName, String className, List<Parameter> parameters, String body, boolean asStatement) {
        StringBuilder source = new StringBuilder();
        if (!packageName.isEmpty()) source.append("package ").append(packageName).append(";\n");
        for (String line : imports) {
            String trimmed = line.trim();
            if (trimmed.isEmpty()) continue;
            source.append(trimmed.startsWith("import ") ? trimmed : "import " + trimmed);
            if (!trimmed.endsWith(";")) source.append(';');
            source.append('\n');
        }
        source.append("@SuppressWarnings(\"all\")\npublic final class ").append(className).append(" {\n");
        source.append("    public static Object eval(");
        for (int i = 0; i < parameters.size(); i++) {
            if (i > 0) source.append(", ");
            source.append("final ").append(parameters.get(i).type).append(' ').append(parameters.get(i).name);
        }
        source.append(") throws Throwable {\n");
        if (asStatement) {
            source.append("        ").append(body).append(";\n        return null;\n");
        } else {
            source.append("        return (").append(body).append(");\n");
        }
        source.append("    }\n}\n");
        return source.toString();
    }

    private boolean compile(JavaCompiler compiler, String qualified, String source, Map<String, byte[]> classes,
                            DiagnosticCollector<JavaFileObject> diagnostics, ThreadReference thread) {
        return compileSource(compiler, qualified, source, classes, diagnostics, classpath(thread));
    }

    /** The program's classpath: what the host sent, else the target's own `java.class.path`. */
    private String classpath(ThreadReference thread) {
        String known = cache.classpath();
        if (known != null) return known;
        try {
            ClassType system = (ClassType) vm.classesByName("java.lang.System").get(0);
            Method getProperty = system.methodsByName("getProperty", "(Ljava/lang/String;)Ljava/lang/String;").get(0);
            Value value = invoke("System.getProperty", () -> system.invokeMethod(thread, getProperty,
                    List.of(vm.mirrorOf("java.class.path")), ClassType.INVOKE_SINGLE_THREADED));
            if (value instanceof StringReference path) {
                cache.setClasspath(path.value());
                return cache.classpath();
            }
        } catch (RuntimeException ignored) {
            // Compile against the JDK alone.
        }
        return null;
    }

    /** `__self` for an instance member of the frame's class, the class itself for a static one. */
    private static String qualifierFor(String name, boolean method, ReferenceType declaring) {
        if (method) {
            List<Method> methods = declaring.methodsByName(name);
            if (methods.isEmpty()) return null;
            boolean allStatic = methods.stream().allMatch(Method::isStatic);
            return allStatic ? (nameable(declaring.name()) ? sourceName(declaring.name()) : null) : "__self";
        }
        Field field = declaring.fieldByName(name);
        if (field == null) return null;
        if (field.isStatic()) return nameable(declaring.name()) ? sourceName(declaring.name()) : null;
        return "__self";
    }

    /** Prefixes every unqualified use of `name` (not after a `.`, not inside a string) with `qualifier.`. */
    static String qualify(String body, String name, String qualifier) {
        StringBuilder out = new StringBuilder();
        int i = 0;
        while (i < body.length()) {
            char c = body.charAt(i);
            if (c == '"' || c == '\'') {
                int end = i + 1;
                while (end < body.length() && body.charAt(end) != c) {
                    if (body.charAt(end) == '\\') end++;
                    end++;
                }
                end = Math.min(end + 1, body.length());
                out.append(body, i, end);
                i = end;
                continue;
            }
            if (Character.isJavaIdentifierStart(c)) {
                int end = i;
                while (end < body.length() && Character.isJavaIdentifierPart(body.charAt(end))) end++;
                String word = body.substring(i, end);
                int before = out.length() - 1;
                while (before >= 0 && Character.isWhitespace(out.charAt(before))) before--;
                boolean qualified = before >= 0 && out.charAt(before) == '.';
                int after = end;
                while (after < body.length() && Character.isWhitespace(body.charAt(after))) after++;
                boolean lambdaParameter = body.startsWith("->", after);
                if (word.equals(name) && !qualified && !lambdaParameter) out.append(qualifier).append('.');
                out.append(word);
                i = end;
                continue;
            }
            out.append(c);
            i++;
        }
        return out.toString();
    }

    // MARK: - Defining the class in the target

    private ClassType define(String qualified, Map<String, byte[]> classes, ClassLoaderReference loader, ThreadReference thread) {
        ClassLoaderReference target = loader != null ? loader : systemLoader(thread);
        ClassType classLoaderType = (ClassType) vm.classesByName("java.lang.ClassLoader").get(0);
        Method defineClass = classLoaderType.methodsByName("defineClass", "(Ljava/lang/String;[BII)Ljava/lang/Class;").get(0);
        ClassObjectReference main = null;
        // Lambdas compile to the main class only; nested classes (an anonymous class) come first.
        List<String> order = new ArrayList<>(classes.keySet());
        order.sort(Comparator.comparing((String name) -> name.equals(qualified)).thenComparing(Comparator.naturalOrder()));
        for (String name : order) {
            byte[] bytes = classes.get(name);
            ArrayReference array = byteArray(bytes);
            List<Value> args = List.of(vm.mirrorOf(name), array, vm.mirrorOf(0), vm.mirrorOf(bytes.length));
            Value defined = invoke("defineClass", () -> target.invokeMethod(thread, defineClass, args, ObjectReference.INVOKE_SINGLE_THREADED));
            if (name.equals(qualified)) main = (ClassObjectReference) defined;
        }
        if (main == null) throw new Evaluator.EvaluationException("The compiled expression is missing.");
        // Initialize it, so its static method can be invoked.
        ClassType classType = (ClassType) vm.classesByName("java.lang.Class").get(0);
        Method forName = classType.methodsByName("forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;").get(0);
        List<Value> args = List.of(vm.mirrorOf(qualified), vm.mirrorOf(true), target);
        invoke("Class.forName", () -> classType.invokeMethod(thread, forName, args, ClassType.INVOKE_SINGLE_THREADED));
        return (ClassType) main.reflectedType();
    }

    private ClassLoaderReference systemLoader(ThreadReference thread) {
        ClassType classLoaderType = (ClassType) vm.classesByName("java.lang.ClassLoader").get(0);
        Method method = classLoaderType.methodsByName("getSystemClassLoader").get(0);
        return (ClassLoaderReference) invoke("getSystemClassLoader",
                () -> classLoaderType.invokeMethod(thread, method, List.of(), ClassType.INVOKE_SINGLE_THREADED));
    }

    private ArrayReference byteArray(byte[] bytes) {
        List<ReferenceType> types = vm.classesByName("byte[]");
        if (types.isEmpty()) throw new Evaluator.EvaluationException("The program has no byte[] class loaded.");
        ArrayReference array = ((ArrayType) types.get(0)).newInstance(bytes.length);
        List<Value> values = new ArrayList<>(bytes.length);
        for (byte b : bytes) values.add(vm.mirrorOf(b));
        try {
            array.setValues(values);
        } catch (InvalidTypeException | ClassNotLoadedException e) {
            throw new Evaluator.EvaluationException("Cannot copy the compiled class: " + e.getMessage());
        }
        return array;
    }

    private interface Invocation {
        Value run() throws Exception;
    }

    private Value invoke(String what, Invocation invocation) {
        beforeInvoke.run();
        try {
            return invocation.run();
        } catch (InvocationException e) {
            ObjectReference exception = e.exception();
            String message = Evaluator.exceptionMessage(exception);
            throw new Evaluator.EvaluationException((what.equals("the expression") ? "The expression" : what + "()") + " threw "
                    + exception.referenceType().name() + (message == null ? "." : ": " + message));
        } catch (IncompatibleThreadStateException e) {
            throw new Evaluator.EvaluationException("The program is not paused.");
        } catch (Evaluator.EvaluationException e) {
            throw e;
        } catch (Exception e) {
            throw new Evaluator.EvaluationException(what + " failed: " + (e.getMessage() == null ? e.toString() : e.getMessage()));
        } finally {
            afterInvoke.run();
        }
    }

    // MARK: - Types

    private static String packageOf(ReferenceType type) {
        String name = type.name();
        int dot = name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(0, dot);
    }

    /** A binary name a source file can write: not anonymous or local (`Foo$1`, `Foo$1Local`). */
    static boolean nameable(String binaryName) {
        String simple = binaryName.substring(binaryName.lastIndexOf('.') + 1);
        for (String part : simple.split("\\$")) {
            if (part.isEmpty() || Character.isDigit(part.charAt(0))) return false;
        }
        return true;
    }

    /** `a.b.Outer$Inner` → `a.b.Outer.Inner`; arrays and primitives as they are. */
    static String sourceName(String binaryName) {
        return binaryName.replace('$', '.');
    }

    /**
     * The source type of a local: its generic signature when it has one without type variables
     * (so `List<Integer>` keeps its element type for a lambda), else its erased name.
     */
    static String sourceType(String genericSignature, String erased) {
        if (genericSignature != null && !genericSignature.isEmpty()) {
            try {
                SignatureReader reader = new SignatureReader(genericSignature);
                String type = reader.type();
                if (reader.atEnd() && !reader.sawTypeVariable && !reader.sawUnnameable) return type;
            } catch (RuntimeException ignored) {
                // An unexpected signature: use the erased type.
            }
        }
        String element = erased;
        String dims = "";
        while (element.endsWith("[]")) {
            element = element.substring(0, element.length() - 2);
            dims += "[]";
        }
        if (!nameable(element)) return "Object";
        return sourceName(element) + dims;
    }

    /** Reads a JVM field type signature (`Ljava/util/List<Ljava/lang/Integer;>;`) into source form. */
    private static final class SignatureReader {
        private final String text;
        private int pos;
        boolean sawTypeVariable;
        boolean sawUnnameable;

        SignatureReader(String text) {
            this.text = text;
        }

        boolean atEnd() {
            return pos == text.length();
        }

        String type() {
            char c = text.charAt(pos++);
            switch (c) {
                case 'B': return "byte";
                case 'C': return "char";
                case 'D': return "double";
                case 'F': return "float";
                case 'I': return "int";
                case 'J': return "long";
                case 'S': return "short";
                case 'Z': return "boolean";
                case 'V': return "void";
                case '[': return type() + "[]";
                case 'T': {
                    sawTypeVariable = true;
                    int end = text.indexOf(';', pos);
                    pos = end + 1;
                    return "Object";
                }
                case 'L': return classType();
                default: throw new IllegalArgumentException("bad signature");
            }
        }

        private String classType() {
            StringBuilder out = new StringBuilder();
            StringBuilder binary = new StringBuilder();
            while (true) {
                char c = text.charAt(pos++);
                if (c == ';') break;
                if (c == '<') {
                    out.append('<');
                    boolean first = true;
                    while (text.charAt(pos) != '>') {
                        if (!first) out.append(", ");
                        first = false;
                        char w = text.charAt(pos);
                        if (w == '*') {
                            pos++;
                            out.append('?');
                        } else if (w == '+') {
                            pos++;
                            out.append("? extends ").append(type());
                        } else if (w == '-') {
                            pos++;
                            out.append("? super ").append(type());
                        } else {
                            out.append(type());
                        }
                    }
                    pos++;
                    out.append('>');
                } else if (c == '/') {
                    out.append('.');
                    binary.append('.');
                } else if (c == '.' || c == '$') {
                    // `.` separates an inner class after type arguments; `$` a nested one.
                    out.append('.');
                    binary.append('$');
                } else {
                    out.append(c);
                    binary.append(c);
                }
            }
            if (!nameable(binary.toString())) sawUnnameable = true;
            return out.toString();
        }
    }

    // MARK: - In-memory compilation

    private static final class Source extends SimpleJavaFileObject {
        private final String code;

        Source(String qualified, String code) {
            super(URI.create("string:///" + qualified.replace('.', '/') + Kind.SOURCE.extension), Kind.SOURCE);
            this.code = code;
        }

        @Override
        public CharSequence getCharContent(boolean ignoreEncodingErrors) {
            return code;
        }
    }

    private static final class Output extends SimpleJavaFileObject {
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private final String name;
        private final Map<String, byte[]> classes;

        Output(String name, Map<String, byte[]> classes) {
            super(URI.create("bytes:///" + name.replace('.', '/') + Kind.CLASS.extension), Kind.CLASS);
            this.name = name;
            this.classes = classes;
        }

        @Override
        public OutputStream openOutputStream() {
            return new OutputStream() {
                @Override
                public void write(int b) {
                    bytes.write(b);
                }

                @Override
                public void write(byte[] b, int off, int len) {
                    bytes.write(b, off, len);
                }

                @Override
                public void close() {
                    classes.put(name, bytes.toByteArray());
                }
            };
        }
    }

    boolean compileSource(JavaCompiler compiler, String qualified, String source, Map<String, byte[]> classes,
                          DiagnosticCollector<JavaFileObject> diagnostics, String classpath) {
        StandardJavaFileManager standard = compiler.getStandardFileManager(diagnostics, Locale.ROOT, StandardCharsets.UTF_8);
        JavaFileManager manager = new ForwardingJavaFileManager<>(standard) {
            @Override
            public JavaFileObject getJavaFileForOutput(Location location, String className, JavaFileObject.Kind kind, FileObject sibling) {
                return new Output(className, classes);
            }
        };
        List<String> options = new ArrayList<>(List.of("-proc:none", "-g", "-nowarn", "-Xlint:none"));
        int release = releaseFor(vm.version());
        if (release > 0) options.addAll(List.of("--release", String.valueOf(release)));
        if (classpath != null) options.addAll(List.of("-classpath", classpath));
        JavaCompiler.CompilationTask task = compiler.getTask(null, manager, diagnostics, options, null,
                List.of(new Source(qualified, source)));
        return Boolean.TRUE.equals(task.call());
    }

    /** The target's feature version, capped at what this compiler supports; 0 to leave it out. */
    static int releaseFor(String vmVersion) {
        int feature;
        try {
            String v = vmVersion.startsWith("1.") ? vmVersion.substring(2) : vmVersion;
            int end = 0;
            while (end < v.length() && Character.isDigit(v.charAt(end))) end++;
            feature = Integer.parseInt(v.substring(0, end));
        } catch (RuntimeException e) {
            return 0;
        }
        int latest = SourceVersion.latestSupported().ordinal();
        feature = Math.max(8, Math.min(feature, latest));
        return feature;
    }
}
