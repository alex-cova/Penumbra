package com.umbra.debug;

import com.sun.jdi.*;
import com.sun.jdi.connect.AttachingConnector;
import com.sun.jdi.connect.Connector;
import com.sun.jdi.event.*;
import com.sun.jdi.request.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * Minimal JDI-backed debug adapter for Umbra. Reads JSON lines from stdin, writes JSON lines to
 * stdout. Events (stopped, terminated) are pushed without a request id.
 */
public final class DebugAdapter {
    private final BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    private final PrintWriter out = new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);
    private final ExecutorService events = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "debug-events");
        t.setDaemon(true);
        return t;
    });

    /** Evaluations run here so a slow {@code toString()} cannot stop the adapter reading commands. */
    private final ExecutorService evaluations = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "debug-evaluate");
        t.setDaemon(true);
        return t;
    });

    private VirtualMachine vm;
    private Process targetProcess;
    private volatile ThreadReference currentThread;
    /** True from a stop (breakpoint, step, pause) until the program is resumed or stepped. */
    private volatile boolean stopped;

    /** Guards {@link #breakpoints}: the request thread and the event thread both resolve them. */
    private final Object breakpointLock = new Object();
    private final List<PendingBreakpoint> breakpoints = new ArrayList<>();
    private final List<Path> sourceRoots = new ArrayList<>();

    /**
     * A breakpoint the user asked for. Its JDI requests exist only once a class holding the line
     * is loaded, so it stays here and is resolved again whenever a class is prepared.
     */
    private static final class PendingBreakpoint {
        final Path file;
        final int line;
        final List<BreakpointRequest> requests = new ArrayList<>();

        PendingBreakpoint(Path file, int line) {
            this.file = file;
            this.line = line;
        }
    }

    public static void main(String[] args) throws Exception {
        new DebugAdapter().run();
    }

    private void run() throws Exception {
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isBlank()) continue;
            Map<String, Object> request = Json.parseObject(line);
            handle(request);
        }
    }

    private void handle(Map<String, Object> request) {
        int id = intValue(request.get("id"));
        String command = stringValue(request.get("command"));
        try {
            switch (command) {
                case "launch" -> launch(request);
                case "attach" -> {
                    readSourceRoots(request);
                    attach(intValue(request.get("port")));
                }
                case "setBreakpoint" -> setBreakpoint(stringValue(request.get("file")), intValue(request.get("line")));
                case "clearBreakpoint" -> clearBreakpoint(stringValue(request.get("file")), intValue(request.get("line")));
                case "resume" -> resume();
                case "stepOver" -> step(StepRequest.STEP_OVER);
                case "stepInto" -> step(StepRequest.STEP_INTO);
                case "stepOut" -> step(StepRequest.STEP_OUT);
                case "pause" -> pause();
                case "stackFrames" -> {
                    stackFrames(id);
                    return;
                }
                case "localVariables" -> {
                    localVariables(id, intValue(request.get("frameIndex")));
                    return;
                }
                case "evaluate" -> {
                    evaluate(id, stringValue(request.get("expression")), request.containsKey("frameIndex") ? intValue(request.get("frameIndex")) : 0);
                    return;
                }
                case "disconnect" -> disconnect();
                default -> {
                    replyError(id, "unknown command: " + command);
                    return;
                }
            }
            replyOk(id);
        } catch (Exception e) {
            replyError(id, e.getMessage() == null ? e.toString() : e.getMessage());
        }
    }

    private void launch(Map<String, Object> request) throws Exception {
        disconnectQuietly();
        String java = stringValue(request.get("java"));
        String classpath = stringValue(request.get("classpath"));
        String mainClass = stringValue(request.get("mainClass"));
        String programArgs = stringValue(request.get("programArgs"));
        String vmArgs = stringValue(request.get("vmArgs"));
        int port = intValue(request.get("port"));
        boolean suspend = boolValue(request.get("suspend"));
        readSourceRoots(request);

        List<String> cmd = new ArrayList<>();
        cmd.add(java);
        for (String token : splitArgs(vmArgs)) cmd.add(token);
        cmd.add("-agentlib:jdwp=transport=dt_socket,server=y,suspend=" + (suspend ? "y" : "n") + ",address=*:" + port);
        cmd.add("-cp");
        cmd.add(classpath);
        cmd.add(mainClass);
        for (String token : splitArgs(programArgs)) cmd.add(token);

        ProcessBuilder pb = new ProcessBuilder(cmd);
        Map<String, String> env = pb.environment();
        Object envObj = request.get("environment");
        if (envObj instanceof Map<?, ?> map) {
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                env.put(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
            }
        }
        pb.redirectErrorStream(true);
        targetProcess = pb.start();
        drainTargetOutput(targetProcess);
        attachWhenListening(port);
    }

    /**
     * The JVM opens its debug port a moment after it starts, so the first attach usually finds
     * nothing listening. Retries until it does, or the target exits.
     */
    private void attachWhenListening(int port) throws Exception {
        Exception last = null;
        for (int attempt = 0; attempt < 150; attempt++) {
            if (targetProcess != null && !targetProcess.isAlive()) {
                throw new IllegalStateException("the program exited with code " + targetProcess.exitValue() + " before it could be debugged");
            }
            try {
                attach(port);
                return;
            } catch (java.net.ConnectException | com.sun.jdi.connect.IllegalConnectorArgumentsException e) {
                last = e;
            } catch (IOException e) {
                last = e;
            }
            Thread.sleep(100);
        }
        throw last != null ? last : new IllegalStateException("could not attach on port " + port);
    }

    /** Reads the target's output so its pipe never fills and blocks it; forwarded as events. */
    private void drainTargetOutput(Process process) {
        Thread t = new Thread(() -> {
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) {
                    emitEvent("output", Map.of("text", line));
                }
            } catch (IOException ignored) {
            }
        }, "target-output");
        t.setDaemon(true);
        t.start();
    }

    /** Directories that hold the program's sources, to turn a class's relative source path into a file. */
    private void readSourceRoots(Map<String, Object> request) {
        sourceRoots.clear();
        if (request.get("sourceRoots") instanceof List<?> roots) {
            for (Object root : roots) {
                sourceRoots.add(Paths.get(String.valueOf(root)).toAbsolutePath().normalize());
            }
        }
    }

    private void attach(int port) throws Exception {
        VirtualMachineManager manager = Bootstrap.virtualMachineManager();
        AttachingConnector connector = manager.attachingConnectors().stream()
                .filter(c -> "dt_socket".equals(c.transport().name()))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException("no socket attaching connector"));
        Map<String, Connector.Argument> args = connector.defaultArguments();
        ((Connector.IntegerArgument) args.get("port")).setValue(port);
        vm = connector.attach(args);
        // Ask for every class as it is prepared, to place breakpoints in classes not yet loaded.
        ClassPrepareRequest prepare = vm.eventRequestManager().createClassPrepareRequest();
        prepare.setSuspendPolicy(EventRequest.SUSPEND_EVENT_THREAD);
        prepare.enable();
        startEventLoop();
    }

    private void startEventLoop() {
        EventQueue queue = vm.eventQueue();
        events.submit(() -> {
            try {
                while (true) {
                    EventSet set = queue.remove();
                    boolean stop = false;
                    for (Event event : set) {
                        if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) {
                            emitEvent("terminated", Map.of());
                            disconnectQuietly();
                            return;
                        }
                        if (event instanceof ClassPrepareEvent prepared) {
                            resolveBreakpoints(prepared.referenceType());
                        } else if (event instanceof BreakpointEvent bp) {
                            reportStop(bp.thread(), bp.location(), "breakpoint");
                            stop = true;
                        } else if (event instanceof StepEvent step) {
                            vm.eventRequestManager().deleteEventRequest(step.request());
                            reportStop(step.thread(), step.location(), "step");
                            stop = true;
                        }
                    }
                    // A stop keeps the program suspended until the user resumes or steps it.
                    if (!stop) set.resume();
                }
            } catch (Exception ignored) {
                emitEvent("terminated", Map.of());
            }
        });
    }

    private void reportStop(ThreadReference thread, Location location, String reason) {
        currentThread = thread;
        stopped = true;
        emitEvent("stopped", Map.of(
                "file", resolveFile(location),
                "line", Math.max(0, location.lineNumber()),
                "reason", reason
        ));
    }

    private void setBreakpoint(String file, int line) {
        ensureVM();
        Path normalized = Paths.get(file).toAbsolutePath().normalize();
        synchronized (breakpointLock) {
            for (PendingBreakpoint existing : breakpoints) {
                if (existing.line == line && existing.file.equals(normalized)) return;
            }
            PendingBreakpoint breakpoint = new PendingBreakpoint(normalized, line);
            breakpoints.add(breakpoint);
            for (ReferenceType type : vm.allClasses()) {
                resolve(breakpoint, type);
            }
        }
    }

    private void clearBreakpoint(String file, int line) {
        if (vm == null) return;
        Path normalized = Paths.get(file).toAbsolutePath().normalize();
        EventRequestManager manager = vm.eventRequestManager();
        synchronized (breakpointLock) {
            Iterator<PendingBreakpoint> iterator = breakpoints.iterator();
            while (iterator.hasNext()) {
                PendingBreakpoint breakpoint = iterator.next();
                if (breakpoint.line != line || !breakpoint.file.equals(normalized)) continue;
                for (BreakpointRequest request : breakpoint.requests) manager.deleteEventRequest(request);
                iterator.remove();
            }
        }
    }

    /** Places every waiting breakpoint that `type` can hold. Called as each class is prepared. */
    private void resolveBreakpoints(ReferenceType type) {
        synchronized (breakpointLock) {
            for (PendingBreakpoint breakpoint : breakpoints) resolve(breakpoint, type);
        }
    }

    private void resolve(PendingBreakpoint breakpoint, ReferenceType type) {
        try {
            if (!type.sourceNames(vm.getDefaultStratum()).contains(breakpoint.file.getFileName().toString())) return;
            for (Location location : type.locationsOfLine(breakpoint.line)) {
                if (!sourceFileMatches(breakpoint.file, location)) continue;
                boolean present = false;
                for (BreakpointRequest request : breakpoint.requests) {
                    if (request.location().equals(location)) present = true;
                }
                if (present) continue;
                BreakpointRequest request = vm.eventRequestManager().createBreakpointRequest(location);
                request.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                request.enable();
                breakpoint.requests.add(request);
            }
        } catch (AbsentInformationException | ClassNotPreparedException | ObjectCollectedException ignored) {
            // No line numbers, not loaded yet, or gone: nothing to place here.
        }
    }

    /** `com/acme/Foo.java` from the class file must end the breakpoint's absolute path. */
    private static boolean sourceFileMatches(Path file, Location location) {
        String relative = sourcePath(location);
        return !relative.isEmpty() && file.endsWith(Paths.get(relative).normalize());
    }

    /** The absolute source file of a location, or its relative source path when no root holds it. */
    private String resolveFile(Location location) {
        String relative = sourcePath(location);
        if (relative.isEmpty()) return "";
        Path relativePath = Paths.get(relative).normalize();
        synchronized (breakpointLock) {
            for (PendingBreakpoint breakpoint : breakpoints) {
                if (breakpoint.file.endsWith(relativePath)) return breakpoint.file.toString();
            }
        }
        for (Path root : sourceRoots) {
            Path candidate = root.resolve(relativePath);
            if (Files.isRegularFile(candidate)) return candidate.toString();
        }
        return relative;
    }

    private void resume() {
        ensureVM();
        clearSteps();
        stopped = false;
        vm.resume();
    }

    private void clearSteps() {
        EventRequestManager manager = vm.eventRequestManager();
        for (StepRequest request : new ArrayList<>(manager.stepRequests())) manager.deleteEventRequest(request);
    }

    /**
     * Runs the stopped thread to its next line: over calls, into them, or out to the caller.
     * Stepping into skips the JDK's own classes, so it lands in the program's code.
     */
    private void step(int depth) {
        ensureVM();
        ensureThread();
        clearSteps();
        StepRequest request = vm.eventRequestManager().createStepRequest(currentThread, StepRequest.STEP_LINE, depth);
        if (depth == StepRequest.STEP_INTO) {
            for (String pattern : RUNTIME_CLASSES) request.addClassExclusionFilter(pattern);
        }
        request.setSuspendPolicy(EventRequest.SUSPEND_ALL);
        request.addCountFilter(1);
        request.enable();
        stopped = false;
        vm.resume();
    }

    private static final String[] RUNTIME_CLASSES = {"java.*", "javax.*", "jdk.*", "sun.*", "com.sun.*"};

    /** Suspends a running program and reports where its main thread is. */
    private void pause() throws IncompatibleThreadStateException {
        ensureVM();
        if (stopped) throw new IllegalStateException("already paused");
        vm.suspend();
        ThreadReference thread = threadToPause();
        if (thread == null) {
            vm.resume();
            throw new IllegalStateException("no thread to pause");
        }
        reportStop(thread, locationToShow(thread), "pause");
    }

    /** The main thread if it has frames, else any other thread of the main group. */
    private ThreadReference threadToPause() {
        ThreadReference fallback = null;
        for (ThreadReference thread : vm.allThreads()) {
            try {
                if (thread.frameCount() == 0) continue;
                ThreadGroupReference group = thread.threadGroup();
                if (group == null || !"main".equals(group.name())) continue;
                if ("main".equals(thread.name())) return thread;
                if (fallback == null) fallback = thread;
            } catch (IncompatibleThreadStateException ignored) {
                // Not suspended after all; skip it.
            }
        }
        return fallback;
    }

    /** The innermost frame in the program's own code; frame 0 when it is all runtime classes. */
    private static Location locationToShow(ThreadReference thread) throws IncompatibleThreadStateException {
        List<StackFrame> frames = thread.frames();
        for (StackFrame frame : frames) {
            Location location = frame.location();
            String type = location.declaringType().name();
            boolean runtime = false;
            for (String pattern : RUNTIME_CLASSES) {
                if (type.startsWith(pattern.substring(0, pattern.length() - 1))) runtime = true;
            }
            if (!runtime && location.lineNumber() > 0) return location;
        }
        return frames.get(0).location();
    }

    private void stackFrames(int id) {
        ensureVM();
        ensureThread();
        List<Map<String, Object>> frames = new ArrayList<>();
        try {
            int index = 0;
            for (StackFrame frame : currentThread.frames()) {
                Location loc = frame.location();
                frames.add(Map.of(
                        "index", index++,
                        "name", frame.location().method().name(),
                        "className", frame.location().declaringType().name(),
                        "file", resolveFile(loc),
                        "line", Math.max(0, loc.lineNumber())
                ));
            }
        } catch (IncompatibleThreadStateException e) {
            throw new IllegalStateException("thread not suspended");
        }
        replyData(id, Map.of("frames", frames));
    }

    private void localVariables(int id, int frameIndex) {
        ensureVM();
        ensureThread();
        List<Map<String, Object>> variables = new ArrayList<>();
        try {
            StackFrame frame = currentThread.frame(frameIndex);
            for (LocalVariable variable : frame.visibleVariables()) {
                Value value = frame.getValue(variable);
                variables.add(Map.of(
                        "name", variable.name(),
                        "type", variable.typeName(),
                        "value", render(value)
                ));
            }
        } catch (Exception e) {
            throw new IllegalStateException(e.getMessage());
        }
        replyData(id, Map.of("variables", variables));
    }

    private void evaluate(int id, String expression, int frameIndex) {
        ensureVM();
        ensureThread();
        if (!stopped) throw new IllegalStateException("The program is running: pause it or wait for a breakpoint.");
        ThreadReference thread = currentThread;
        VirtualMachine machine = vm;
        evaluations.submit(() -> {
            try {
                Evaluator evaluator = new Evaluator(machine, thread, frameIndex, this::disableBreakpoints, this::enableBreakpoints);
                replyData(id, Map.of("result", evaluator.evaluate(expression)));
            } catch (Evaluator.EvaluationException e) {
                replyError(id, e.getMessage());
            } catch (VMDisconnectedException e) {
                replyError(id, "The program has ended.");
            } catch (Exception e) {
                replyError(id, e.getMessage() == null ? e.toString() : e.getMessage());
            }
        });
    }

    /**
     * A method invoked for an evaluation must not stop at a breakpoint of its own: the invoking
     * thread would wait for a resume that never comes.
     */
    private void disableBreakpoints() {
        synchronized (breakpointLock) {
            for (PendingBreakpoint breakpoint : breakpoints) {
                for (BreakpointRequest request : breakpoint.requests) request.disable();
            }
        }
    }

    private void enableBreakpoints() {
        synchronized (breakpointLock) {
            for (PendingBreakpoint breakpoint : breakpoints) {
                for (BreakpointRequest request : breakpoint.requests) request.enable();
            }
        }
    }

    private void disconnect() {
        disconnectQuietly();
    }

    private void disconnectQuietly() {
        if (vm != null) {
            try { vm.dispose(); } catch (Exception ignored) {}
            vm = null;
        }
        if (targetProcess != null) {
            targetProcess.destroyForcibly();
            targetProcess = null;
        }
        currentThread = null;
        stopped = false;
        synchronized (breakpointLock) {
            breakpoints.clear();
        }
    }

    private void ensureVM() {
        if (vm == null) throw new IllegalStateException("not connected");
    }

    private void ensureThread() {
        if (currentThread == null) throw new IllegalStateException("no suspended thread");
    }

    private static String sourcePath(Location location) {
        try {
            return location.sourcePath();
        } catch (AbsentInformationException e) {
            return "";
        }
    }

    private static String render(Value value) {
        if (value == null) return "null";
        return value.toString();
    }

    private static List<String> splitArgs(String text) {
        if (text == null || text.isBlank()) return List.of();
        List<String> tokens = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        boolean quote = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\'') { quote = !quote; continue; }
            if (Character.isWhitespace(c) && !quote) {
                if (!current.isEmpty()) { tokens.add(current.toString()); current.setLength(0); }
                continue;
            }
            current.append(c);
        }
        if (!current.isEmpty()) tokens.add(current.toString());
        return tokens;
    }

    private void replyOk(int id) {
        out.println(Json.stringify(Map.of("id", id, "ok", true)));
    }

    private void replyError(int id, String message) {
        out.println(Json.stringify(Map.of("id", id, "ok", false, "error", message)));
    }

    private void replyData(int id, Map<String, Object> data) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("id", id);
        payload.put("ok", true);
        payload.putAll(data);
        out.println(Json.stringify(payload));
    }

    private void emitEvent(String name, Map<String, Object> body) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("event", name);
        payload.putAll(body);
        out.println(Json.stringify(payload));
    }

    private static String stringValue(Object value) {
        return value == null ? "" : String.valueOf(value);
    }

    private static int intValue(Object value) {
        if (value instanceof Number number) return number.intValue();
        return Integer.parseInt(String.valueOf(value));
    }

    private static boolean boolValue(Object value) {
        if (value instanceof Boolean b) return b;
        return Boolean.parseBoolean(String.valueOf(value));
    }
}
