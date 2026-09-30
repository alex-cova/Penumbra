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
 * JDI-backed debug adapter for Umbra. Reads JSON lines from stdin, writes JSON lines to stdout.
 * Events (stopped, output, breakpointVerified, breakpointRemoved, terminated) are pushed without a
 * request id.
 *
 * <p>Breakpoints are keyed by the host's id and come in four kinds: line, exception, method and
 * field. Each carries a condition, a suspend policy (all threads, the event thread, or none), log
 * output, remove-once-hit and a pass count. A hit is judged off the event loop, on the evaluation
 * executor, because a condition may invoke code in the target, and the class loading that code
 * triggers needs the event loop to keep resuming class-prepare events.
 */
public final class DebugAdapter {
    private final BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    private final PrintWriter out = new PrintWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);
    private final ExecutorService events = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "debug-events");
        t.setDaemon(true);
        return t;
    });

    /** Evaluations and breakpoint hits run here, so a slow condition cannot stop the adapter reading commands. */
    private final ExecutorService evaluations = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "debug-evaluate");
        t.setDaemon(true);
        return t;
    });

    private volatile VirtualMachine vm;
    private Process targetProcess;
    private volatile OutputForwarder outputForwarder;
    private final List<Thread> outputThreads = new ArrayList<>();

    /** Guards the stop state: {@link #currentThread}, {@link #stopped}, {@link #pendingStops}. */
    private final Object stopLock = new Object();
    private volatile ThreadReference currentThread;
    /** True from a stop (breakpoint, step, pause) until the program is resumed or stepped. */
    private volatile boolean stopped;
    /** Whether the stop being shown suspended every thread, or only its own. */
    private volatile boolean stopSuspendsAll = true;
    /** Threads stopped by a thread-only breakpoint while another stop was showing; shown next. */
    private final Deque<Stop> pendingStops = new ArrayDeque<>();

    /** Guards {@link #breakpoints}: the request thread, the event thread and hits all use them. */
    private final Object breakpointLock = new Object();
    private final Map<String, Breakpoint> breakpoints = new LinkedHashMap<>();
    private volatile boolean muted;
    /** Method invocations in progress for evaluations; breakpoints stay off while any runs. */
    private int invocations;
    /** Breakpoints muted by Force Run to Cursor, unmuted when it arrives. */
    private boolean forcedMute;
    private final List<Path> sourceRoots = new ArrayList<>();
    private final CompilingEvaluator.Cache compileCache = new CompilingEvaluator.Cache();
    /** Objects opened from the memory view, kept from collection until the program runs again. */
    private final Map<Long, ObjectReference> pinned = new ConcurrentHashMap<>();
    /** Nanoseconds spent stepping, for the overhead view. */
    private volatile long steppingNanos;
    private volatile long stepStarted;

    private static final String BREAKPOINT = "umbra.breakpoint";
    private static final String SMART_STEP = "umbra.smartStep";
    private static final String RUN_TO_CURSOR = "__runToCursor";

    private enum Kind { LINE, EXCEPTION, METHOD, FIELD }

    /**
     * A breakpoint the user asked for. Its JDI requests exist only once a class it applies to is
     * loaded, so it stays here and is resolved again whenever a class is prepared.
     */
    private static final class Breakpoint {
        final String id;
        final Kind kind;
        final Path file;
        final int line;
        final String className;
        final String memberName;
        final boolean caught;
        final boolean uncaught;
        final boolean access;
        final boolean modification;
        final String condition;
        final Evaluator.Node conditionTree;
        /** {@link EventRequest#SUSPEND_ALL}, {@code SUSPEND_EVENT_THREAD} or {@code SUSPEND_NONE}. */
        final int suspendPolicy;
        final boolean logMessage;
        final String logExpression;
        final Evaluator.Node logTree;
        final boolean removeOnceHit;
        final int passCount;
        final boolean temporary;
        final List<String> imports;
        final List<EventRequest> requests = new ArrayList<>();
        /** Null until a class this could apply to is prepared. */
        Boolean verified;
        boolean expired;
        long hits;
        long nanos;

        Breakpoint(Map<String, Object> spec, boolean temporary) {
            this.temporary = temporary;
            String kindName = stringValue(spec.get("kind"));
            kind = switch (kindName) {
                case "exception" -> Kind.EXCEPTION;
                case "method" -> Kind.METHOD;
                case "field" -> Kind.FIELD;
                default -> Kind.LINE;
            };
            String filePath = stringValue(spec.get("file"));
            file = filePath.isEmpty() ? null : Paths.get(filePath).toAbsolutePath().normalize();
            line = spec.containsKey("line") ? intValue(spec.get("line")) : 0;
            String givenID = stringValue(spec.get("breakpointId"));
            id = !givenID.isEmpty() ? givenID : (file == null ? kindName + ":" + stringValue(spec.get("className")) : file + ":" + line);
            className = stringValue(spec.get("className"));
            memberName = stringValue(spec.containsKey("methodName") ? spec.get("methodName") : spec.get("fieldName"));
            caught = !spec.containsKey("caught") || boolValue(spec.get("caught"));
            uncaught = !spec.containsKey("uncaught") || boolValue(spec.get("uncaught"));
            access = boolValue(spec.get("access"));
            modification = !spec.containsKey("modification") || boolValue(spec.get("modification"));
            String cond = stringValue(spec.get("condition")).trim();
            condition = cond.isEmpty() ? null : cond;
            conditionTree = condition == null ? null : parseOrNull(condition);
            suspendPolicy = switch (stringValue(spec.get("suspendPolicy"))) {
                case "thread" -> EventRequest.SUSPEND_EVENT_THREAD;
                case "none" -> EventRequest.SUSPEND_NONE;
                default -> EventRequest.SUSPEND_ALL;
            };
            logMessage = boolValue(spec.get("logMessage"));
            String log = stringValue(spec.get("logExpression")).trim();
            logExpression = log.isEmpty() ? null : log;
            logTree = logExpression == null ? null : parseOrNull(logExpression);
            removeOnceHit = boolValue(spec.get("removeOnceHit"));
            passCount = spec.containsKey("passCount") ? Math.max(0, intValue(spec.get("passCount"))) : 0;
            List<String> list = new ArrayList<>();
            if (spec.get("imports") instanceof List<?> given) for (Object entry : given) list.add(String.valueOf(entry));
            imports = list;
        }

        private static Evaluator.Node parseOrNull(String text) {
            try {
                return Evaluator.parse(text);
            } catch (Evaluator.EvaluationException e) {
                return null;
            }
        }

        /**
         * The policy its requests suspend with. A breakpoint that suspends nothing but has to
         * evaluate something still needs its thread held while it does.
         */
        int requestPolicy() {
            if (suspendPolicy == EventRequest.SUSPEND_NONE && (condition != null || logExpression != null)) {
                return EventRequest.SUSPEND_EVENT_THREAD;
            }
            return suspendPolicy;
        }

        String reason() {
            return switch (kind) {
                case EXCEPTION -> "exception";
                case METHOD -> "method";
                case FIELD -> "watchpoint";
                default -> temporary ? "runToCursor" : "breakpoint";
            };
        }
    }

    /** A stop waiting to be reported. */
    private record Stop(ThreadReference thread, Location location, String reason, boolean suspendsAll, Map<String, Object> extra) {}

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
                    compileCache.setClasspath(stringValue(request.get("classpath")));
                    attach(intValue(request.get("port")));
                }
                case "setBreakpoint" -> setBreakpoint(request);
                case "clearBreakpoint" -> clearBreakpoint(request);
                case "muteBreakpoints" -> setMuted(boolValue(request.get("muted")));
                case "resume" -> resume();
                case "stepOver" -> step(StepRequest.STEP_OVER, true);
                case "stepInto" -> step(StepRequest.STEP_INTO, true);
                case "forceStepInto" -> step(StepRequest.STEP_INTO, false);
                case "stepOut" -> step(StepRequest.STEP_OUT, true);
                case "smartStepInto" -> smartStepInto(stringValue(request.get("methodName")));
                case "runToCursor" -> runToCursor(stringValue(request.get("file")), intValue(request.get("line")), boolValue(request.get("force")));
                case "pause" -> pause();
                case "dropFrame" -> dropFrame(intValue(request.get("frameIndex")));
                case "selectThread" -> selectThread(longValue(request.get("threadId")));
                case "threads" -> {
                    threads(id);
                    return;
                }
                case "stackFrames" -> {
                    stackFrames(id);
                    return;
                }
                case "localVariables" -> {
                    localVariables(id, intValue(request.get("frameIndex")));
                    return;
                }
                case "evaluate" -> {
                    evaluate(id, stringValue(request.get("expression")), frameIndex(request), imports(request));
                    return;
                }
                case "setValue" -> {
                    evaluate(id, stringValue(request.get("target")) + " = " + stringValue(request.get("value")), frameIndex(request), imports(request));
                    return;
                }
                case "forceReturn" -> {
                    forceReturn(id, stringValue(request.get("expression")), imports(request));
                    return;
                }
                case "traceStream" -> {
                    traceStream(id, stringValue(request.get("expression")), frameIndex(request), imports(request));
                    return;
                }
                case "instanceCounts" -> {
                    instanceCounts(id);
                    return;
                }
                case "instances" -> {
                    instances(id, stringValue(request.get("className")), request.containsKey("limit") ? intValue(request.get("limit")) : 1000);
                    return;
                }
                case "overhead" -> {
                    overhead(id);
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

    private static int frameIndex(Map<String, Object> request) {
        return request.containsKey("frameIndex") ? intValue(request.get("frameIndex")) : 0;
    }

    private static List<String> imports(Map<String, Object> request) {
        List<String> list = new ArrayList<>();
        if (request.get("imports") instanceof List<?> given) for (Object entry : given) list.add(String.valueOf(entry));
        return list;
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
        compileCache.setClasspath(classpath);

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
        // stdout and stderr stay separate so the console can tell them apart.
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

    /**
     * Reads the target's stdout and stderr so their pipes never fill and block it, and forwards
     * them as batched {@code output} events (see {@link OutputForwarder}).
     */
    private void drainTargetOutput(Process process) {
        OutputForwarder forwarder = new OutputForwarder();
        outputForwarder = forwarder;
        outputThreads.clear();
        outputThreads.add(readStream(process.getInputStream(), OutputForwarder.OUT, forwarder));
        outputThreads.add(readStream(process.getErrorStream(), OutputForwarder.ERR, forwarder));
    }

    private Thread readStream(InputStream stream, int index, OutputForwarder forwarder) {
        Thread t = new Thread(() -> {
            char[] buffer = new char[8192];
            try (Reader reader = new InputStreamReader(stream, StandardCharsets.UTF_8)) {
                int count;
                while ((count = reader.read(buffer)) != -1) {
                    forwarder.accept(index, buffer, count);
                }
            } catch (IOException ignored) {
            }
            forwarder.finish(index);
        }, index == OutputForwarder.OUT ? "target-stdout" : "target-stderr");
        t.setDaemon(true);
        t.start();
        return t;
    }

    /**
     * Turns the target's output into events without flooding the host. Complete lines are batched
     * into one {@code output} event, sent every {@link #FLUSH_MILLIS} ms or as soon as
     * {@link #MAX_BATCH} lines wait. A line still open after {@link #PARTIAL_MILLIS} ms of silence
     * (a prompt written without a newline) goes out with {@code partial: true}; the host appends
     * the rest of that line to it when it arrives. Order between the two streams is approximate.
     */
    private final class OutputForwarder {
        static final int OUT = 0;
        static final int ERR = 1;
        static final int MAX_BATCH = 200;
        static final int MAX_PARTIAL = 8192;
        static final long FLUSH_MILLIS = 50;
        static final long PARTIAL_MILLIS = 100;

        private final Object lock = new Object();
        private final List<Map<String, Object>> pending = new ArrayList<>();
        private final StringBuilder[] open = { new StringBuilder(), new StringBuilder() };
        private final long[] lastWrite = new long[2];
        private boolean tickScheduled;
        private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "target-output-flush");
            t.setDaemon(true);
            return t;
        });

        void accept(int stream, char[] chars, int count) {
            synchronized (lock) {
                StringBuilder line = open[stream];
                for (int i = 0; i < count; i++) {
                    char c = chars[i];
                    if (c == '\n') {
                        int length = line.length();
                        if (length > 0 && line.charAt(length - 1) == '\r') line.setLength(length - 1);
                        addLine(stream, line.toString(), false);
                        line.setLength(0);
                        // A read can hold many lines; keep every event to MAX_BATCH.
                        if (pending.size() >= MAX_BATCH) flushLocked();
                    } else {
                        line.append(c);
                        if (line.length() >= MAX_PARTIAL) {
                            addLine(stream, line.toString(), true);
                            line.setLength(0);
                        }
                    }
                }
                lastWrite[stream] = System.nanoTime();
                if (pending.isEmpty()) {
                    if (line.length() > 0) scheduleLocked();
                } else {
                    scheduleLocked();
                }
            }
        }

        /** The stream ended: an unterminated last line is complete. */
        void finish(int stream) {
            synchronized (lock) {
                if (open[stream].length() > 0) {
                    addLine(stream, open[stream].toString(), false);
                    open[stream].setLength(0);
                }
                flushLocked();
            }
        }

        /** Sends whatever is waiting, including lines still open. */
        /** Stops the flush timer without sending anything: the session is being replaced or closed. */
        void discard() {
            timer.shutdownNow();
        }

        void flushAll() {
            synchronized (lock) {
                for (int stream = OUT; stream <= ERR; stream++) {
                    if (open[stream].length() > 0) {
                        addLine(stream, open[stream].toString(), true);
                        open[stream].setLength(0);
                    }
                }
                flushLocked();
            }
            timer.shutdown();
        }

        private void addLine(int stream, String text, boolean partial) {
            Map<String, Object> line = new LinkedHashMap<>();
            line.put("stream", stream == OUT ? "out" : "err");
            line.put("text", text);
            line.put("partial", partial);
            pending.add(line);
        }

        private void flushLocked() {
            if (pending.isEmpty()) return;
            emitEvent("output", Map.of("lines", new ArrayList<Object>(pending)));
            pending.clear();
        }

        private void scheduleLocked() {
            if (tickScheduled || timer.isShutdown()) return;
            tickScheduled = true;
            try {
                timer.schedule(this::tick, FLUSH_MILLIS, TimeUnit.MILLISECONDS);
            } catch (RejectedExecutionException e) {
                tickScheduled = false;
            }
        }

        private void tick() {
            synchronized (lock) {
                tickScheduled = false;
                long now = System.nanoTime();
                boolean stillOpen = false;
                for (int stream = OUT; stream <= ERR; stream++) {
                    if (open[stream].length() == 0) continue;
                    if (TimeUnit.NANOSECONDS.toMillis(now - lastWrite[stream]) >= PARTIAL_MILLIS) {
                        addLine(stream, open[stream].toString(), true);
                        open[stream].setLength(0);
                    } else {
                        stillOpen = true;
                    }
                }
                flushLocked();
                if (stillOpen) scheduleLocked();
            }
        }
    }

    /**
     * Ends the session's output and reports {@code terminated} with the program's exit code when
     * it has one (a launched program that exited; an attach session has no process).
     */
    private void emitTerminated() {
        Process process = targetProcess;
        Map<String, Object> body = new LinkedHashMap<>();
        boolean exited = false;
        if (process != null) {
            try {
                exited = process.waitFor(2, TimeUnit.SECONDS);
                if (exited) body.put("exitCode", process.exitValue());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        OutputForwarder forwarder = outputForwarder;
        if (forwarder != null) {
            // Once the program has exited both pipes end, so the readers finish with the last lines.
            if (exited) {
                for (Thread reader : outputThreads) {
                    try { reader.join(500); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                }
            }
            forwarder.flushAll();
        }
        emitEvent("terminated", body);
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

    // MARK: - Events

    private record Hit(Breakpoint breakpoint, LocatableEvent event) {}

    private void startEventLoop() {
        VirtualMachine machine = vm;
        EventQueue queue = machine.eventQueue();
        events.submit(() -> {
            try {
                while (true) {
                    EventSet set = queue.remove();
                    Stop stop = null;
                    List<Hit> hits = new ArrayList<>();
                    for (Event event : set) {
                        if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) {
                            emitTerminated();
                            disconnectQuietly();
                            return;
                        }
                        if (event instanceof ClassPrepareEvent prepared) {
                            resolveBreakpoints(prepared.referenceType());
                        } else if (event instanceof StepEvent step) {
                            clearSmartStep();
                            machine.eventRequestManager().deleteEventRequest(step.request());
                            noteSteppingDone();
                            stop = new Stop(step.thread(), step.location(), "step", set.suspendPolicy() == EventRequest.SUSPEND_ALL, Map.of());
                        } else if (event instanceof MethodEntryEvent entry && entry.request().getProperty(SMART_STEP) instanceof String target) {
                            if (entry.method().name().equals(target) && stop == null) {
                                clearSmartStep();
                                noteSteppingDone();
                                // The entries were reported for the stepping thread alone; hold every
                                // thread, as a step does.
                                machine.suspend();
                                entry.thread().resume();
                                stop = new Stop(entry.thread(), entry.location(), "step", true, Map.of());
                            }
                        } else if (event instanceof LocatableEvent locatable && event.request() != null
                                && event.request().getProperty(BREAKPOINT) instanceof Breakpoint breakpoint) {
                            hits.add(new Hit(breakpoint, locatable));
                        }
                    }
                    if (stop != null) {
                        reportStop(stop);
                    } else if (!hits.isEmpty()) {
                        // Judged off this loop: a condition may run code in the target.
                        evaluations.submit(() -> judge(set, hits));
                    } else {
                        set.resume();
                    }
                }
            } catch (Exception ignored) {
                emitTerminated();
            }
        });
    }

    /**
     * Decides whether the breakpoints in one event set stop the program: counts the hit, checks the
     * condition, writes the log output, and removes a remove-once-hit breakpoint that stopped.
     */
    private void judge(EventSet set, List<Hit> hits) {
        Stop stop = null;
        try {
            for (Hit hit : hits) {
                Breakpoint breakpoint = hit.breakpoint;
                ThreadReference thread = hit.event.thread();
                long started = System.nanoTime();
                synchronized (breakpointLock) {
                    if (!breakpoints.containsValue(breakpoint)) continue; // cleared meanwhile
                    breakpoint.hits++;
                    if (breakpoint.passCount > 0) breakpoint.expired = true;
                }
                if (breakpoint.temporary) {
                    stop = new Stop(thread, hit.event.location(), "runToCursor", true, Map.of());
                    continue;
                }
                Map<String, Object> extra = new LinkedHashMap<>();
                extra.put("breakpointId", breakpoint.id);
                if (hit.event instanceof ExceptionEvent exception) {
                    ObjectReference thrown = exception.exception();
                    String message = Evaluator.exceptionMessage(thrown);
                    extra.put("message", thrown.referenceType().name() + (message == null ? "" : ": " + message));
                }
                boolean passes = true;
                if (breakpoint.condition != null) {
                    try {
                        Evaluator evaluator = evaluator(thread, 0, breakpoint.imports);
                        Evaluator.Node tree = breakpoint.conditionTree != null ? breakpoint.conditionTree : Evaluator.parse(breakpoint.condition);
                        passes = evaluator.condition(tree, breakpoint.condition);
                    } catch (Evaluator.EvaluationException | VMDisconnectedException e) {
                        // As in IntelliJ: a condition that cannot be evaluated stops, and says why.
                        extra.put("message", "The condition '" + breakpoint.condition + "' failed: " + e.getMessage());
                        extra.put("conditionError", true);
                        record(breakpoint, started);
                        stop = new Stop(thread, hit.event.location(), "conditionError", true, extra);
                        continue;
                    }
                }
                if (!passes) {
                    record(breakpoint, started);
                    continue;
                }
                log(breakpoint, thread, hit.event);
                record(breakpoint, started);
                if (breakpoint.suspendPolicy == EventRequest.SUSPEND_NONE) continue;
                if (breakpoint.removeOnceHit) {
                    removeBreakpoint(breakpoint.id);
                    emitEvent("breakpointRemoved", Map.of("id", breakpoint.id));
                }
                if (stop == null) {
                    boolean all = set.suspendPolicy() == EventRequest.SUSPEND_ALL;
                    stop = new Stop(thread, hit.event.location(), breakpoint.reason(), all, extra);
                }
            }
        } catch (VMDisconnectedException e) {
            return;
        } catch (RuntimeException e) {
            emitLog("Umbra could not check a breakpoint: " + e.getMessage());
        }
        if (stop != null) {
            reportStop(stop);
        } else {
            try {
                set.resume();
            } catch (VMDisconnectedException ignored) {
            }
        }
    }

    private void record(Breakpoint breakpoint, long started) {
        synchronized (breakpointLock) {
            breakpoint.nanos += System.nanoTime() - started;
        }
    }

    /** "Breakpoint reached" and the log expression, as `log` lines in the program's console. */
    private void log(Breakpoint breakpoint, ThreadReference thread, LocatableEvent event) {
        if (breakpoint.logMessage) {
            Location location = event.location();
            String file = location.declaringType().name();
            try {
                file = location.sourceName();
            } catch (AbsentInformationException ignored) {
            }
            emitLog("Breakpoint reached at " + location.declaringType().name() + "." + location.method().name()
                    + "(" + file + ":" + location.lineNumber() + ")");
        }
        if (breakpoint.logExpression != null) {
            try {
                Evaluator evaluator = evaluator(thread, 0, breakpoint.imports);
                Evaluator.Node tree = breakpoint.logTree != null ? breakpoint.logTree : Evaluator.parse(breakpoint.logExpression);
                emitLog(evaluator.text(evaluator.value(tree, breakpoint.logExpression)));
            } catch (Evaluator.EvaluationException e) {
                emitLog("Cannot evaluate '" + breakpoint.logExpression + "': " + e.getMessage());
            }
        }
    }

    private void emitLog(String text) {
        Map<String, Object> line = new LinkedHashMap<>();
        line.put("stream", "log");
        line.put("text", text);
        line.put("partial", false);
        emitEvent("output", Map.of("lines", List.of(line)));
    }

    /**
     * Shows a stop, or queues it while another is showing (a second thread stopped by a thread-only
     * breakpoint stays suspended until the first is resumed).
     */
    private void reportStop(Stop stop) {
        synchronized (stopLock) {
            if (stopped) {
                pendingStops.add(stop);
                return;
            }
            currentThread = stop.thread;
            stopped = true;
            stopSuspendsAll = stop.suspendsAll;
        }
        endRunToCursor();
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("file", resolveFile(stop.location));
        body.put("line", Math.max(0, stop.location.lineNumber()));
        body.put("reason", stop.reason);
        body.put("threadId", stop.thread.uniqueID());
        body.put("threadName", safeName(stop.thread));
        body.put("suspendsAll", stop.suspendsAll);
        body.putAll(stop.extra);
        emitEvent("stopped", body);
    }

    private static String safeName(ThreadReference thread) {
        try {
            return thread.name();
        } catch (ObjectCollectedException | VMDisconnectedException e) {
            return "";
        }
    }

    // MARK: - Breakpoints

    private void setBreakpoint(Map<String, Object> spec) {
        ensureVM();
        Breakpoint breakpoint = new Breakpoint(spec, false);
        if (breakpoint.kind == Kind.LINE && breakpoint.file == null) throw new IllegalArgumentException("a line breakpoint needs a file");
        if (breakpoint.kind != Kind.LINE && breakpoint.className.isEmpty() && breakpoint.kind != Kind.EXCEPTION) {
            throw new IllegalArgumentException("a " + breakpoint.kind.name().toLowerCase(Locale.ROOT) + " breakpoint needs a class");
        }
        if (breakpoint.kind == Kind.FIELD && (breakpoint.access ? !vm.canWatchFieldAccess() : !vm.canWatchFieldModification())) {
            throw new IllegalStateException("This JVM cannot watch fields.");
        }
        synchronized (breakpointLock) {
            removeBreakpoint(breakpoint.id);
            breakpoints.put(breakpoint.id, breakpoint);
            place(breakpoint);
        }
    }

    private void clearBreakpoint(Map<String, Object> request) {
        if (vm == null) return;
        String id = stringValue(request.get("breakpointId"));
        if (id.isEmpty()) {
            Path file = Paths.get(stringValue(request.get("file"))).toAbsolutePath().normalize();
            id = file + ":" + intValue(request.get("line"));
        }
        synchronized (breakpointLock) {
            removeBreakpoint(id);
        }
    }

    /** Caller holds {@link #breakpointLock} or accepts the race with a hit being judged. */
    private void removeBreakpoint(String id) {
        synchronized (breakpointLock) {
            Breakpoint existing = breakpoints.remove(id);
            if (existing == null || vm == null) return;
            EventRequestManager manager = vm.eventRequestManager();
            for (EventRequest request : existing.requests) {
                try {
                    manager.deleteEventRequest(request);
                } catch (VMDisconnectedException ignored) {
                }
            }
            existing.requests.clear();
        }
    }

    /** Places a new breakpoint in the classes already loaded. Caller holds {@link #breakpointLock}. */
    private void place(Breakpoint breakpoint) {
        switch (breakpoint.kind) {
            case LINE -> {
                String sourceName = breakpoint.file.getFileName().toString();
                for (ReferenceType type : vm.allClasses()) {
                    if (hasSource(type, sourceName)) resolve(breakpoint, type);
                }
            }
            case EXCEPTION -> {
                if (breakpoint.className.isEmpty() || breakpoint.className.equals("*")) {
                    ExceptionRequest request = vm.eventRequestManager().createExceptionRequest(null, breakpoint.caught, breakpoint.uncaught);
                    configure(breakpoint, request);
                    setVerified(breakpoint, true);
                } else {
                    for (ReferenceType type : vm.classesByName(breakpoint.className)) resolve(breakpoint, type);
                }
            }
            default -> {
                for (ReferenceType type : vm.classesByName(breakpoint.className)) resolve(breakpoint, type);
            }
        }
    }

    private static boolean hasSource(ReferenceType type, String sourceName) {
        try {
            return type.sourceName().equals(sourceName);
        } catch (AbsentInformationException | ObjectCollectedException e) {
            return false;
        }
    }

    /** Places every waiting breakpoint that `type` can hold. Called as each class is prepared. */
    private void resolveBreakpoints(ReferenceType type) {
        synchronized (breakpointLock) {
            for (Breakpoint breakpoint : breakpoints.values()) {
                switch (breakpoint.kind) {
                    case LINE -> {
                        if (hasSource(type, breakpoint.file.getFileName().toString())) resolve(breakpoint, type);
                    }
                    case EXCEPTION -> {
                        if (type.name().equals(breakpoint.className)) resolve(breakpoint, type);
                    }
                    default -> {
                        if (type.name().equals(breakpoint.className)) resolve(breakpoint, type);
                    }
                }
            }
        }
    }

    /** Creates `breakpoint`'s requests in `type`. Caller holds {@link #breakpointLock}. */
    private void resolve(Breakpoint breakpoint, ReferenceType type) {
        try {
            EventRequestManager manager = vm.eventRequestManager();
            switch (breakpoint.kind) {
                case LINE -> {
                    boolean placed = false;
                    for (Location location : type.locationsOfLine(breakpoint.line)) {
                        if (!sourceFileMatches(breakpoint.file, location)) continue;
                        placed = true;
                        if (hasRequestAt(breakpoint, location)) continue;
                        configure(breakpoint, manager.createBreakpointRequest(location));
                    }
                    // Only a placed location is reported: a line with no code in this class may
                    // still belong to a nested or local class of the same file not loaded yet.
                    if (placed) setVerified(breakpoint, true);
                }
                case METHOD -> {
                    // A line breakpoint at each overload's first instruction: much cheaper than
                    // method-entry events, which fire for every method of the class.
                    for (Method method : type.methodsByName(breakpoint.memberName)) {
                        if (method.isAbstract() || method.isNative()) continue;
                        Location location = method.location();
                        if (location == null || hasRequestAt(breakpoint, location)) continue;
                        configure(breakpoint, manager.createBreakpointRequest(location));
                    }
                    setVerified(breakpoint, !breakpoint.requests.isEmpty());
                }
                case FIELD -> {
                    Field field = type.fieldByName(breakpoint.memberName);
                    if (field == null) {
                        setVerified(breakpoint, false);
                        return;
                    }
                    if (!breakpoint.requests.isEmpty()) return;
                    if (breakpoint.access && vm.canWatchFieldAccess()) {
                        configure(breakpoint, manager.createAccessWatchpointRequest(field));
                    }
                    if (breakpoint.modification && vm.canWatchFieldModification()) {
                        configure(breakpoint, manager.createModificationWatchpointRequest(field));
                    }
                    setVerified(breakpoint, !breakpoint.requests.isEmpty());
                }
                case EXCEPTION -> {
                    if (!breakpoint.requests.isEmpty()) return;
                    configure(breakpoint, manager.createExceptionRequest(type, breakpoint.caught, breakpoint.uncaught));
                    setVerified(breakpoint, true);
                }
            }
        } catch (AbsentInformationException | ClassNotPreparedException | ObjectCollectedException ignored) {
            // No line numbers, not loaded yet, or gone: nothing to place here.
        }
    }

    private static boolean hasRequestAt(Breakpoint breakpoint, Location location) {
        for (EventRequest request : breakpoint.requests) {
            if (request instanceof BreakpointRequest existing && existing.location().equals(location)) return true;
        }
        return false;
    }

    private void configure(Breakpoint breakpoint, EventRequest request) {
        request.setSuspendPolicy(breakpoint.requestPolicy());
        if (breakpoint.passCount > 0) request.addCountFilter(breakpoint.passCount);
        request.putProperty(BREAKPOINT, breakpoint);
        breakpoint.requests.add(request);
        // A class prepared during an evaluation's call must not get a live breakpoint: it could
        // stop the invoking thread while the evaluation waits on it.
        if ((!muted || breakpoint.temporary) && invocations == 0) request.enable();
    }

    private void setVerified(Breakpoint breakpoint, boolean verified) {
        if (breakpoint.temporary || Objects.equals(breakpoint.verified, verified)) return;
        if (Boolean.TRUE.equals(breakpoint.verified)) return; // one placed location is enough
        breakpoint.verified = verified;
        emitEvent("breakpointVerified", Map.of("id", breakpoint.id, "verified", verified));
    }

    /** Mute Breakpoints: every breakpoint stays, none of them fires. */
    private void setMuted(boolean muted) {
        synchronized (breakpointLock) {
            this.muted = muted;
            forcedMute = false;
            applyEnabled(invocations == 0);
        }
    }

    /** Turns every request on or off to match the mute state. Caller holds {@link #breakpointLock}. */
    private void applyEnabled(boolean enabled) {
        for (Breakpoint breakpoint : breakpoints.values()) {
            boolean on = enabled && (breakpoint.temporary || !muted) && !breakpoint.expired;
            for (EventRequest request : breakpoint.requests) {
                try {
                    request.setEnabled(on);
                } catch (InvalidRequestStateException | VMDisconnectedException ignored) {
                }
            }
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
            for (Breakpoint breakpoint : breakpoints.values()) {
                if (breakpoint.file != null && breakpoint.file.endsWith(relativePath)) return breakpoint.file.toString();
            }
        }
        for (Path root : sourceRoots) {
            Path candidate = root.resolve(relativePath);
            if (Files.isRegularFile(candidate)) return candidate.toString();
        }
        return relative;
    }

    // MARK: - Running and stepping

    /**
     * Lets the stopped program go: every thread for a stop that held them all, only the stopped
     * thread otherwise. A thread-only stop that was waiting behind it is shown next.
     */
    private void resume() {
        ensureVM();
        clearSteps();
        Stop next;
        synchronized (stopLock) {
            boolean all = stopSuspendsAll;
            ThreadReference thread = currentThread;
            stopped = false;
            releasePinned();
            if (all || thread == null) {
                pendingStops.clear(); // their threads are resumed too
                vm.resume();
            } else {
                thread.resume();
            }
            next = pendingStops.poll();
        }
        if (next != null) reportStop(next);
    }

    private void clearSteps() {
        EventRequestManager manager = vm.eventRequestManager();
        for (StepRequest request : new ArrayList<>(manager.stepRequests())) manager.deleteEventRequest(request);
        clearSmartStep();
    }

    private void clearSmartStep() {
        VirtualMachine machine = vm;
        if (machine == null) return;
        EventRequestManager manager = machine.eventRequestManager();
        for (MethodEntryRequest request : new ArrayList<>(manager.methodEntryRequests())) {
            if (request.getProperty(SMART_STEP) != null) manager.deleteEventRequest(request);
        }
    }

    /**
     * Runs the stopped thread to its next line: over calls, into them, or out to the caller.
     * Stepping into skips the JDK's own classes unless `filtered` is off (Force Step Into).
     */
    private void step(int depth, boolean filtered) {
        ensureVM();
        ensureStopped();
        clearSteps();
        StepRequest request = vm.eventRequestManager().createStepRequest(currentThread, StepRequest.STEP_LINE, depth);
        if (depth == StepRequest.STEP_INTO && filtered) {
            for (String pattern : stepFilters()) request.addClassExclusionFilter(pattern);
        }
        request.setSuspendPolicy(stopSuspendsAll ? EventRequest.SUSPEND_ALL : EventRequest.SUSPEND_EVENT_THREAD);
        request.addCountFilter(1);
        request.enable();
        letStoppedThreadRun();
    }

    /** Resumes for a step: the stop ends, but no queued stop is shown before the step lands. */
    private void letStoppedThreadRun() {
        synchronized (stopLock) {
            stopped = false;
            releasePinned();
            stepStarted = System.nanoTime();
            if (stopSuspendsAll) vm.resume();
            else currentThread.resume();
        }
    }

    private void noteSteppingDone() {
        long started = stepStarted;
        if (started != 0) steppingNanos += System.nanoTime() - started;
        stepStarted = 0;
    }

    private static final String[] RUNTIME_CLASSES = {"java.*", "javax.*", "jdk.*", "sun.*", "com.sun.*"};
    private volatile String[] stepFilters = RUNTIME_CLASSES;

    private String[] stepFilters() {
        return stepFilters;
    }

    /**
     * Smart Step Into: steps into the call named `methodName` on the current line, skipping the
     * calls before it. If the line finishes without entering it, stops at the next line instead.
     */
    private void smartStepInto(String methodName) {
        ensureVM();
        ensureStopped();
        if (methodName.isEmpty()) throw new IllegalArgumentException("no method to step into");
        clearSteps();
        EventRequestManager manager = vm.eventRequestManager();
        MethodEntryRequest entry = manager.createMethodEntryRequest();
        entry.addThreadFilter(currentThread);
        entry.setSuspendPolicy(EventRequest.SUSPEND_EVENT_THREAD);
        entry.putProperty(SMART_STEP, methodName);
        entry.enable();
        StepRequest fallback = manager.createStepRequest(currentThread, StepRequest.STEP_LINE, StepRequest.STEP_OVER);
        fallback.setSuspendPolicy(stopSuspendsAll ? EventRequest.SUSPEND_ALL : EventRequest.SUSPEND_EVENT_THREAD);
        fallback.addCountFilter(1);
        fallback.enable();
        letStoppedThreadRun();
    }

    /**
     * Run to Cursor: a one-time breakpoint on `line`, then resume. Other breakpoints still stop the
     * program on the way unless `force` mutes them until the cursor is reached.
     */
    private void runToCursor(String file, int line, boolean force) {
        ensureVM();
        ensureStopped();
        Map<String, Object> spec = new HashMap<>();
        spec.put("breakpointId", RUN_TO_CURSOR);
        spec.put("file", file);
        spec.put("line", line);
        Breakpoint cursor = new Breakpoint(spec, true);
        synchronized (breakpointLock) {
            removeBreakpoint(RUN_TO_CURSOR);
            breakpoints.put(RUN_TO_CURSOR, cursor);
            place(cursor);
            if (cursor.requests.isEmpty()) {
                breakpoints.remove(RUN_TO_CURSOR);
                throw new IllegalStateException("There is no code to run to on line " + line + ".");
            }
            if (force && !muted) {
                muted = true;
                forcedMute = true;
                applyEnabled(true);
            }
        }
        resume();
    }

    /** Any stop ends Run to Cursor, whether it got there or another breakpoint stopped it first. */
    private void endRunToCursor() {
        synchronized (breakpointLock) {
            if (!breakpoints.containsKey(RUN_TO_CURSOR)) return;
            removeBreakpoint(RUN_TO_CURSOR);
            if (forcedMute) {
                muted = false;
                forcedMute = false;
                applyEnabled(true);
            }
        }
    }

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
        reportStop(new Stop(thread, locationToShow(thread), "pause", true, Map.of()));
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
            if (!isLibrary(location.declaringType().name()) && location.lineNumber() > 0) return location;
        }
        return frames.get(0).location();
    }

    private static boolean isLibrary(String className) {
        for (String pattern : RUNTIME_CLASSES) {
            if (className.startsWith(pattern.substring(0, pattern.length() - 1))) return true;
        }
        return false;
    }

    /**
     * Drop Frame: pops `frameIndex` and every frame above it, so the caller re-runs the call. The
     * thread stays suspended, now at the call.
     */
    private void dropFrame(int frameIndex) throws Exception {
        ensureVM();
        ensureStopped();
        if (!vm.canPopFrames()) throw new IllegalStateException("This JVM cannot drop frames.");
        ThreadReference thread = currentThread;
        List<StackFrame> frames = thread.frames();
        if (frameIndex < 0 || frameIndex >= frames.size() - 1) throw new IllegalStateException("The bottom frame cannot be dropped.");
        clearSteps();
        thread.popFrames(frames.get(frameIndex));
        Location location = thread.frame(0).location();
        synchronized (stopLock) {
            stopped = false;
        }
        reportStop(new Stop(thread, location, "dropFrame", stopSuspendsAll, Map.of()));
    }

    /**
     * Force Return: the current method returns at once, with `expression`'s value (nothing for a
     * `void` method), and the program stops again in the caller.
     */
    private void forceReturn(int id, String expression, List<String> imports) {
        ensureVM();
        ensureStopped();
        if (!vm.canForceEarlyReturn()) throw new IllegalStateException("This JVM cannot force a return.");
        ThreadReference thread = currentThread;
        VirtualMachine machine = vm;
        evaluations.submit(() -> {
            try {
                Method method = thread.frame(0).location().method();
                Value value;
                if (method.returnTypeName().equals("void")) {
                    value = machine.mirrorOfVoid();
                } else {
                    if (expression.isBlank()) throw new Evaluator.EvaluationException(method.name() + "() returns " + method.returnTypeName() + ": enter a value.");
                    value = evaluator(thread, 0, imports).value(expression);
                }
                thread.forceEarlyReturn(value);
                step(StepRequest.STEP_OVER, true);
                replyOk(id);
            } catch (Evaluator.EvaluationException e) {
                replyError(id, e.getMessage());
            } catch (InvalidTypeException e) {
                replyError(id, "The value does not match the method's return type.");
            } catch (Exception e) {
                replyError(id, e.getMessage() == null ? e.toString() : e.getMessage());
            }
        });
    }

    // MARK: - Threads, frames, variables

    private void threads(int id) {
        ensureVM();
        List<Map<String, Object>> list = new ArrayList<>();
        ThreadReference current = currentThread;
        for (ThreadReference thread : vm.allThreads()) {
            try {
                Map<String, Object> entry = new LinkedHashMap<>();
                entry.put("id", thread.uniqueID());
                entry.put("name", thread.name());
                ThreadGroupReference group = thread.threadGroup();
                entry.put("group", group == null ? "" : group.name());
                entry.put("status", status(thread.status()));
                entry.put("suspended", thread.isSuspended());
                entry.put("current", thread.equals(current));
                list.add(entry);
            } catch (ObjectCollectedException ignored) {
            }
        }
        replyData(id, Map.of("threads", list));
    }

    private static String status(int status) {
        return switch (status) {
            case ThreadReference.THREAD_STATUS_RUNNING -> "running";
            case ThreadReference.THREAD_STATUS_SLEEPING -> "sleeping";
            case ThreadReference.THREAD_STATUS_WAIT -> "waiting";
            case ThreadReference.THREAD_STATUS_MONITOR -> "monitor";
            case ThreadReference.THREAD_STATUS_ZOMBIE -> "finished";
            case ThreadReference.THREAD_STATUS_NOT_STARTED -> "not started";
            default -> "unknown";
        };
    }

    /** Inspects another suspended thread: frames, variables and evaluation follow it. */
    private void selectThread(long threadId) {
        ensureVM();
        ensureStopped();
        for (ThreadReference thread : vm.allThreads()) {
            if (thread.uniqueID() != threadId) continue;
            if (!thread.isSuspended()) throw new IllegalStateException("That thread is running.");
            currentThread = thread;
            return;
        }
        throw new IllegalStateException("No such thread.");
    }

    private void stackFrames(int id) {
        ensureVM();
        ensureThread();
        List<Map<String, Object>> frames = new ArrayList<>();
        try {
            int index = 0;
            for (StackFrame frame : currentThread.frames()) {
                Location loc = frame.location();
                String className = loc.declaringType().name();
                Map<String, Object> entry = new LinkedHashMap<>();
                entry.put("index", index++);
                entry.put("name", loc.method().name());
                entry.put("className", className);
                entry.put("file", resolveFile(loc));
                entry.put("line", Math.max(0, loc.lineNumber()));
                entry.put("library", isLibrary(className));
                frames.add(entry);
            }
        } catch (IncompatibleThreadStateException e) {
            throw new IllegalStateException("thread not suspended");
        }
        replyData(id, Map.of("frames", frames));
    }

    /** The frame's `this` and locals, each a value node that can be opened by evaluating its expression. */
    private void localVariables(int id, int frameIndex) {
        ensureVM();
        ensureThread();
        List<Map<String, Object>> variables = new ArrayList<>();
        try {
            StackFrame frame = currentThread.frame(frameIndex);
            Evaluator evaluator = evaluator(currentThread, frameIndex, List.of());
            ObjectReference self = frame.thisObject();
            if (self != null) variables.add(evaluator.node("this", self, "this", false));
            try {
                for (LocalVariable variable : frame.visibleVariables()) {
                    Map<String, Object> node = evaluator.node(variable.name(), frame.getValue(variable), variable.name(), false);
                    node.put("type", variable.typeName());
                    variables.add(node);
                }
            } catch (AbsentInformationException ignored) {
                // Compiled without -g: `this` only.
            }
        } catch (Exception e) {
            throw new IllegalStateException(e.getMessage());
        }
        replyData(id, Map.of("variables", variables));
    }

    private Evaluator evaluator(ThreadReference thread, int frameIndex, List<String> imports) {
        VirtualMachine machine = vm;
        CompilingEvaluator compiler = new CompilingEvaluator(machine, compileCache, imports, this::disableBreakpoints, this::enableBreakpoints);
        return new Evaluator(machine, thread, frameIndex, this::disableBreakpoints, this::enableBreakpoints, pinned, compiler);
    }

    private void evaluate(int id, String expression, int frameIndex, List<String> imports) {
        ensureVM();
        ensureThread();
        if (!stopped) throw new IllegalStateException("The program is running: pause it or wait for a breakpoint.");
        ThreadReference thread = currentThread;
        evaluations.submit(() -> {
            try {
                Evaluator evaluator = evaluator(thread, frameIndex, imports);
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
            invocations++;
            applyEnabled(false);
        }
    }

    private void enableBreakpoints() {
        synchronized (breakpointLock) {
            invocations = Math.max(0, invocations - 1);
            if (invocations == 0) applyEnabled(true);
        }
    }

    // MARK: - Stream trace

    /**
     * Evaluates a stream chain the host rewrote to record each stage (see JavaStreamChain): the
     * value is an `Object[]` of one `Object[]` per stage, each holding `{long time, Object value}`
     * records, then the terminal result. Each value comes back as text with an identity, so the
     * host can link an element to the ones it became.
     */
    private void traceStream(int id, String expression, int frameIndex, List<String> imports) {
        ensureVM();
        ensureThread();
        if (!stopped) throw new IllegalStateException("The program is running: pause it or wait for a breakpoint.");
        ThreadReference thread = currentThread;
        evaluations.submit(() -> {
            try {
                Evaluator evaluator = evaluator(thread, frameIndex, imports);
                Value value = evaluator.value(expression);
                if (!(value instanceof ArrayReference stages) || stages.length() < 1) {
                    throw new Evaluator.EvaluationException("The traced stream returned nothing.");
                }
                List<Map<String, Object>> result = new ArrayList<>();
                List<Value> all = stages.getValues();
                for (int s = 0; s < all.size() - 1; s++) {
                    List<Map<String, Object>> records = new ArrayList<>();
                    if (all.get(s) instanceof ArrayReference stage) {
                        int count = Math.min(stage.length(), 500);
                        for (Value recordValue : stage.getValues(0, count)) {
                            if (!(recordValue instanceof ArrayReference record) || record.length() < 2) continue;
                            Object time = Evaluator.unboxOrNull(record.getValue(0));
                            Value element = record.getValue(1);
                            Map<String, Object> entry = new LinkedHashMap<>();
                            entry.put("time", time instanceof Number n ? n.longValue() : 0L);
                            entry.put("value", streamText(evaluator, element));
                            entry.put("identity", identity(element));
                            records.add(entry);
                        }
                        if (stage.length() > count) {
                            Map<String, Object> more = new LinkedHashMap<>();
                            more.put("time", Long.MAX_VALUE);
                            more.put("value", "… " + (stage.length() - count) + " more");
                            more.put("identity", "more");
                            records.add(more);
                        }
                    }
                    result.add(Map.of("values", records));
                }
                Value terminal = all.get(all.size() - 1);
                replyData(id, Map.of("stages", result, "result", evaluator.node(null, terminal, "", true)));
            } catch (Evaluator.EvaluationException e) {
                replyError(id, e.getMessage());
            } catch (VMDisconnectedException e) {
                replyError(id, "The program has ended.");
            } catch (Exception e) {
                replyError(id, e.getMessage() == null ? e.toString() : e.getMessage());
            }
        });
    }

    private static String streamText(Evaluator evaluator, Value value) {
        if (value instanceof StringReference || value instanceof PrimitiveValue || value == null) return Evaluator.display(value);
        if (value instanceof ObjectReference object && Evaluator.BOXES.contains(object.referenceType().name())) return Evaluator.display(value);
        try {
            String text = evaluator.text(value);
            return text.length() > 120 ? text.substring(0, 120) + "…" : text;
        } catch (Evaluator.EvaluationException e) {
            return Evaluator.display(value);
        }
    }

    /** The same object in two stages has the same identity; equal primitives do too. */
    private static String identity(Value value) {
        if (value instanceof ObjectReference object) return "#" + object.uniqueID();
        return "=" + Evaluator.display(value);
    }

    // MARK: - Memory and overhead

    /** How many instances of each loaded class the heap holds (classes with none are left out). */
    private void instanceCounts(int id) {
        ensureVM();
        if (!vm.canGetInstanceInfo()) throw new IllegalStateException("This JVM cannot count instances.");
        ensureStopped();
        List<ReferenceType> classes = vm.allClasses();
        long[] counts = vm.instanceCounts(classes);
        List<Map<String, Object>> list = new ArrayList<>();
        for (int i = 0; i < classes.size(); i++) {
            if (counts[i] == 0) continue;
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("className", classes.get(i).name());
            entry.put("count", counts[i]);
            list.add(entry);
        }
        list.sort((a, b) -> Long.compare((Long) b.get("count"), (Long) a.get("count")));
        replyData(id, Map.of("classes", list));
    }

    /** Up to `limit` instances of a class, pinned so they can be opened by `#id` until the program runs. */
    private void instances(int id, String className, int limit) {
        ensureVM();
        ensureThread();
        if (!vm.canGetInstanceInfo()) throw new IllegalStateException("This JVM cannot list instances.");
        List<ReferenceType> types = vm.classesByName(className);
        if (types.isEmpty()) throw new IllegalStateException("The class " + className + " is not loaded.");
        Evaluator evaluator = evaluator(currentThread, 0, List.of());
        List<Map<String, Object>> nodes = new ArrayList<>();
        int index = 0;
        for (ObjectReference object : types.get(0).instances(Math.max(1, Math.min(limit, 5000)))) {
            try {
                object.disableCollection();
            } catch (ObjectCollectedException e) {
                continue;
            }
            pinned.put(object.uniqueID(), object);
            nodes.add(evaluator.node("[" + index++ + "]", object, "#" + object.uniqueID(), false));
        }
        replyData(id, Map.of("instances", nodes));
    }

    private void releasePinned() {
        for (ObjectReference object : pinned.values()) {
            try {
                object.enableCollection();
            } catch (ObjectCollectedException | VMDisconnectedException ignored) {
            }
        }
        pinned.clear();
    }

    private void overhead(int id) {
        List<Map<String, Object>> list = new ArrayList<>();
        synchronized (breakpointLock) {
            for (Breakpoint breakpoint : breakpoints.values()) {
                if (breakpoint.temporary) continue;
                Map<String, Object> entry = new LinkedHashMap<>();
                entry.put("id", breakpoint.id);
                entry.put("hits", breakpoint.hits);
                entry.put("millis", breakpoint.nanos / 1_000_000.0);
                list.add(entry);
            }
        }
        replyData(id, Map.of("breakpoints", list, "steppingMillis", steppingNanos / 1_000_000.0));
    }

    // MARK: - Session

    private void disconnect() {
        disconnectQuietly();
    }

    private void disconnectQuietly() {
        VirtualMachine machine = vm;
        if (machine != null) {
            releasePinned();
            try { machine.dispose(); } catch (Exception ignored) {}
            vm = null;
        }
        if (targetProcess != null) {
            targetProcess.destroyForcibly();
            targetProcess = null;
        }
        OutputForwarder forwarder = outputForwarder;
        if (forwarder != null) {
            forwarder.discard();
            outputForwarder = null;
        }
        synchronized (stopLock) {
            currentThread = null;
            stopped = false;
            pendingStops.clear();
        }
        synchronized (breakpointLock) {
            breakpoints.clear();
            muted = false;
            forcedMute = false;
        }
        compileCache.clear();
    }

    private void ensureVM() {
        if (vm == null) throw new IllegalStateException("not connected");
    }

    private void ensureThread() {
        if (currentThread == null) throw new IllegalStateException("no suspended thread");
    }

    private void ensureStopped() {
        ensureThread();
        if (!stopped) throw new IllegalStateException("The program is running.");
    }

    private static String sourcePath(Location location) {
        try {
            return location.sourcePath();
        } catch (AbsentInformationException e) {
            return "";
        }
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

    private static long longValue(Object value) {
        if (value instanceof Number number) return number.longValue();
        return Long.parseLong(String.valueOf(value));
    }

    private static boolean boolValue(Object value) {
        if (value instanceof Boolean b) return b;
        return Boolean.parseBoolean(String.valueOf(value));
    }
}
