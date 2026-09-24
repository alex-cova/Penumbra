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

    private VirtualMachine vm;
    private Process targetProcess;
    private ThreadReference currentThread;

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
                case "attach" -> attach(intValue(request.get("port")));
                case "setBreakpoint" -> setBreakpoint(stringValue(request.get("file")), intValue(request.get("line")));
                case "clearBreakpoint" -> clearBreakpoint(stringValue(request.get("file")), intValue(request.get("line")));
                case "resume" -> resume();
                case "stepOver" -> stepOver();
                case "stackFrames" -> {
                    stackFrames(id);
                    return;
                }
                case "localVariables" -> {
                    localVariables(id, intValue(request.get("frameIndex")));
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
        targetProcess = pb.start();
        attach(port);
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
        startEventLoop();
    }

    private void startEventLoop() {
        EventQueue queue = vm.eventQueue();
        events.submit(() -> {
            try {
                while (true) {
                    EventSet set = queue.remove();
                    for (Event event : set) {
                        if (event instanceof VMDeathEvent || event instanceof VMDisconnectEvent) {
                            emitEvent("terminated", Map.of());
                            disconnectQuietly();
                            return;
                        }
                        if (event instanceof BreakpointEvent bp) {
                            currentThread = bp.thread();
                            Location loc = bp.location();
                            emitEvent("stopped", Map.of(
                                    "file", sourcePath(loc),
                                    "line", loc.lineNumber(),
                                    "reason", "breakpoint"
                            ));
                        }
                        if (event instanceof StepEvent step) {
                            currentThread = step.thread();
                            Location loc = step.location();
                            emitEvent("stopped", Map.of(
                                    "file", sourcePath(loc),
                                    "line", loc.lineNumber(),
                                    "reason", "step"
                            ));
                        }
                    }
                    set.resume();
                }
            } catch (Exception ignored) {
                emitEvent("terminated", Map.of());
            }
        });
    }

    private void setBreakpoint(String file, int line) throws Exception {
        ensureVM();
        Path normalized = Paths.get(file).toAbsolutePath().normalize();
        for (ReferenceType type : vm.allClasses()) {
            for (Location loc : type.allLineLocations()) {
                if (loc.lineNumber() != line) continue;
                if (!normalized.equals(Paths.get(sourcePath(loc)).toAbsolutePath().normalize())) continue;
                BreakpointRequest req = vm.eventRequestManager().createBreakpointRequest(loc);
                req.enable();
                return;
            }
        }
        throw new IllegalStateException("no executable location for " + file + ":" + line);
    }

    private void clearBreakpoint(String file, int line) {
        if (vm == null) return;
        Path normalized = Paths.get(file).toAbsolutePath().normalize();
        EventRequestManager manager = vm.eventRequestManager();
        for (EventRequest request : manager.breakpointRequests()) {
            if (!(request instanceof BreakpointRequest bp)) continue;
            Location loc = bp.location();
            if (loc.lineNumber() != line) continue;
            if (!normalized.equals(Paths.get(sourcePath(loc)).toAbsolutePath().normalize())) continue;
            manager.deleteEventRequest(request);
        }
    }

    private void resume() throws InvalidStackFrameException {
        ensureVM();
        if (currentThread != null) {
            for (EventRequest request : vm.eventRequestManager().stepRequests()) {
                if (request instanceof StepRequest step && step.thread().equals(currentThread)) {
                    vm.eventRequestManager().deleteEventRequest(request);
                }
            }
            currentThread.resume();
        } else {
            vm.resume();
        }
    }

    private void stepOver() throws InvalidStackFrameException {
        ensureVM();
        ensureThread();
        EventRequestManager manager = vm.eventRequestManager();
        for (EventRequest request : manager.stepRequests()) manager.deleteEventRequest(request);
        StepRequest step = manager.createStepRequest(currentThread, StepRequest.STEP_LINE, StepRequest.STEP_OVER);
        step.addCountFilter(1);
        step.enable();
        currentThread.resume();
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
                        "file", sourcePath(loc),
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
