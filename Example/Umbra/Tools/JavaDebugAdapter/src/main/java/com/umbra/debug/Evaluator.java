package com.umbra.debug;

import com.sun.jdi.*;

import java.util.*;

/**
 * Evaluates the small expression language a debugger can answer with JDI alone, against one
 * frame of a suspended thread.
 *
 * <p>Supported: locals, fields of {@code this} and of the frame's class, {@code a.b.c},
 * {@code arr[i]} (the index is any supported expression that is an integer), {@code arr.length},
 * literals (int, long, double, float, char, string, boolean, null) and {@code toString()}.
 * Anything else (operators, calls with arguments, lambdas, casts, {@code new}) is refused with a
 * message saying so, because JDI has no evaluator: that would need compiling code into the target.
 *
 * <p>Frames become invalid after a method invocation, so the frame is fetched again whenever it
 * is needed.
 */
final class Evaluator {
    static final class EvaluationException extends RuntimeException {
        EvaluationException(String message) {
            super(message);
        }
    }

    static final String UNSUPPORTED =
            "Not supported: operators and method calls with arguments. "
                    + "Evaluate handles variables, fields, array elements, literals and toString().";

    private static final int MAX_CHILDREN = 100;
    private static final int MAX_STRING = 200;
    private static final Set<String> BOXES = Set.of(
            "java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte",
            "java.lang.Character", "java.lang.Boolean", "java.lang.Float", "java.lang.Double");

    private final VirtualMachine vm;
    private final ThreadReference thread;
    private final int frameIndex;
    /** Runs around a method invocation, so a breakpoint inside {@code toString()} cannot hang it. */
    private final Runnable beforeInvoke;
    private final Runnable afterInvoke;

    private String text = "";
    private int pos;

    Evaluator(VirtualMachine vm, ThreadReference thread, int frameIndex, Runnable beforeInvoke, Runnable afterInvoke) {
        this.vm = vm;
        this.thread = thread;
        this.frameIndex = frameIndex;
        this.beforeInvoke = beforeInvoke;
        this.afterInvoke = afterInvoke;
    }

    /** The value of {@code expression}, as the node the panel shows (with its children, one level). */
    Map<String, Object> evaluate(String expression) {
        Value value = value(expression);
        return node(null, value, expression.trim(), true);
    }

    Value value(String expression) {
        text = expression;
        pos = 0;
        skipWhitespace();
        if (pos >= text.length()) throw new EvaluationException("Enter an expression.");
        Value value = expression();
        skipWhitespace();
        if (pos < text.length()) throw unsupportedAt();
        return value;
    }

    // MARK: - Parsing

    private Value expression() {
        Value value = primary();
        while (true) {
            skipWhitespace();
            if (pos >= text.length()) return value;
            char c = text.charAt(pos);
            if (c == '.') {
                pos++;
                skipWhitespace();
                String name = identifier();
                if (name == null) throw new EvaluationException("Expected a name after '.'.");
                skipWhitespace();
                if (peek('(')) {
                    value = call(value, name);
                } else {
                    value = member(value, name);
                }
            } else if (c == '[') {
                pos++;
                Value index = expression();
                skipWhitespace();
                if (!peek(']')) throw new EvaluationException("Expected ']'.");
                pos++;
                value = element(value, index);
            } else {
                return value;
            }
        }
    }

    private Value primary() {
        skipWhitespace();
        if (pos >= text.length()) throw new EvaluationException("The expression ends too soon.");
        char c = text.charAt(pos);
        if (Character.isDigit(c) || (c == '-' && pos + 1 < text.length() && Character.isDigit(text.charAt(pos + 1)))) {
            return number();
        }
        if (c == '"') return string();
        if (c == '\'') return character();
        String name = identifier();
        if (name == null) throw unsupportedAt();
        skipWhitespace();
        if (peek('(')) throw new EvaluationException(UNSUPPORTED);
        switch (name) {
            case "true": return vm.mirrorOf(true);
            case "false": return vm.mirrorOf(false);
            case "null": return null;
            case "this": {
                ObjectReference self = frame().thisObject();
                if (self == null) throw new EvaluationException("There is no 'this' in a static method.");
                return self;
            }
            default:
                try {
                    return variable(name);
                } catch (EvaluationException e) {
                    skipWhitespace();
                    if (peek('.') && Character.isUpperCase(name.charAt(0))) {
                        throw new EvaluationException(e.getMessage() + " Static members of a class (Math.max, Foo.BAR) are not supported.");
                    }
                    throw e;
                }
        }
    }

    private Value number() {
        int start = pos;
        if (text.charAt(pos) == '-') pos++;
        while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
        boolean floating = false;
        if (pos + 1 < text.length() && text.charAt(pos) == '.' && Character.isDigit(text.charAt(pos + 1))) {
            floating = true;
            pos++;
            while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
        }
        String digits = text.substring(start, pos);
        char suffix = pos < text.length() ? Character.toLowerCase(text.charAt(pos)) : ' ';
        try {
            if (suffix == 'l' && !floating) {
                pos++;
                return vm.mirrorOf(Long.parseLong(digits));
            }
            if (suffix == 'f') {
                pos++;
                return vm.mirrorOf(Float.parseFloat(digits));
            }
            if (suffix == 'd') {
                pos++;
                return vm.mirrorOf(Double.parseDouble(digits));
            }
            if (floating) return vm.mirrorOf(Double.parseDouble(digits));
            return vm.mirrorOf(Integer.parseInt(digits));
        } catch (NumberFormatException e) {
            throw new EvaluationException("Not a number: " + digits);
        }
    }

    private Value string() {
        pos++;
        StringBuilder out = new StringBuilder();
        while (pos < text.length() && text.charAt(pos) != '"') {
            char c = text.charAt(pos++);
            if (c == '\\' && pos < text.length()) c = unescape(text.charAt(pos++));
            out.append(c);
        }
        if (pos >= text.length()) throw new EvaluationException("The string is not closed.");
        pos++;
        return vm.mirrorOf(out.toString());
    }

    private Value character() {
        pos++;
        if (pos >= text.length()) throw new EvaluationException("The character is not closed.");
        char c = text.charAt(pos++);
        if (c == '\\' && pos < text.length()) c = unescape(text.charAt(pos++));
        if (pos >= text.length() || text.charAt(pos) != '\'') throw new EvaluationException("The character is not closed.");
        pos++;
        return vm.mirrorOf(c);
    }

    private static char unescape(char c) {
        return switch (c) {
            case 'n' -> '\n';
            case 't' -> '\t';
            case 'r' -> '\r';
            case '0' -> '\0';
            default -> c;
        };
    }

    private String identifier() {
        int start = pos;
        while (pos < text.length()) {
            char c = text.charAt(pos);
            boolean ok = pos == start ? Character.isJavaIdentifierStart(c) : Character.isJavaIdentifierPart(c);
            if (!ok) break;
            pos++;
        }
        return pos == start ? null : text.substring(start, pos);
    }

    private boolean peek(char c) {
        return pos < text.length() && text.charAt(pos) == c;
    }

    private void skipWhitespace() {
        while (pos < text.length() && Character.isWhitespace(text.charAt(pos))) pos++;
    }

    private EvaluationException unsupportedAt() {
        String rest = text.substring(Math.min(pos, text.length())).trim();
        if (rest.length() > 20) rest = rest.substring(0, 20) + "…";
        char c = rest.isEmpty() ? ' ' : rest.charAt(0);
        boolean operator = "+-*/%<>=!&|?:(),^~{}".indexOf(c) >= 0;
        return new EvaluationException(operator ? UNSUPPORTED : "Cannot read '" + rest + "'. " + UNSUPPORTED);
    }

    // MARK: - Evaluation

    private StackFrame frame() {
        try {
            return thread.frame(frameIndex);
        } catch (IncompatibleThreadStateException e) {
            throw new EvaluationException("The program is not paused.");
        } catch (IndexOutOfBoundsException e) {
            throw new EvaluationException("There is no such stack frame.");
        }
    }

    private Value variable(String name) {
        StackFrame frame = frame();
        try {
            LocalVariable local = frame.visibleVariableByName(name);
            if (local != null) return frame.getValue(local);
        } catch (AbsentInformationException e) {
            // Compiled without -g: locals are unreadable, fields still work.
        }
        ObjectReference self = frame.thisObject();
        if (self != null) {
            Field field = self.referenceType().fieldByName(name);
            if (field != null) return field.isStatic() ? self.referenceType().getValue(field) : self.getValue(field);
        }
        ReferenceType declaring = frame.location().declaringType();
        Field field = declaring.fieldByName(name);
        if (field != null && field.isStatic()) return declaring.getValue(field);
        boolean noLocals = false;
        try {
            frame.visibleVariables();
        } catch (AbsentInformationException e) {
            noLocals = true;
        }
        throw new EvaluationException("Cannot find '" + name + "'." + (noLocals ? " The class was compiled without -g, so local variables are not available." : ""));
    }

    private Value member(Value receiver, String name) {
        if (receiver == null) throw new EvaluationException("Cannot read '" + name + "' of null.");
        if (receiver instanceof ArrayReference array) {
            if (name.equals("length")) return vm.mirrorOf(array.length());
            throw new EvaluationException("An array has no member '" + name + "'.");
        }
        if (!(receiver instanceof ObjectReference object)) {
            throw new EvaluationException("A " + receiver.type().name() + " has no member '" + name + "'.");
        }
        Field field = object.referenceType().fieldByName(name);
        if (field == null) throw new EvaluationException(object.referenceType().name() + " has no field '" + name + "'.");
        return field.isStatic() ? object.referenceType().getValue(field) : object.getValue(field);
    }

    private Value element(Value receiver, Value index) {
        if (receiver == null) throw new EvaluationException("Cannot index null.");
        if (!(receiver instanceof ArrayReference array)) throw new EvaluationException("Only arrays can be indexed.");
        int i;
        if (index instanceof IntegerValue v) i = v.value();
        else if (index instanceof ShortValue v) i = v.value();
        else if (index instanceof ByteValue v) i = v.value();
        else if (index instanceof CharValue v) i = v.value();
        else throw new EvaluationException("An array index must be an int.");
        if (i < 0 || i >= array.length()) {
            throw new EvaluationException("Index " + i + " is out of bounds for length " + array.length() + ".");
        }
        return array.getValue(i);
    }

    private Value call(Value receiver, String name) {
        pos++; // (
        skipWhitespace();
        if (!peek(')')) throw new EvaluationException(UNSUPPORTED);
        pos++;
        if (!name.equals("toString")) {
            throw new EvaluationException("Only toString() can be called: '" + name + "()' is not supported.");
        }
        if (receiver == null) throw new EvaluationException("Cannot call toString() on null.");
        if (receiver instanceof StringReference) return receiver;
        if (!(receiver instanceof ObjectReference object)) {
            throw new EvaluationException("toString() needs an object, not a " + receiver.type().name() + ".");
        }
        List<Method> methods = object.referenceType().methodsByName("toString", "()Ljava/lang/String;");
        if (methods.isEmpty()) throw new EvaluationException(object.referenceType().name() + " has no toString().");
        beforeInvoke.run();
        try {
            return object.invokeMethod(thread, methods.get(0), List.of(), ObjectReference.INVOKE_SINGLE_THREADED);
        } catch (InvocationException e) {
            throw new EvaluationException("toString() threw " + e.exception().referenceType().name() + ".");
        } catch (IncompatibleThreadStateException e) {
            throw new EvaluationException("The program is not paused.");
        } catch (InvalidTypeException | ClassNotLoadedException e) {
            throw new EvaluationException("toString() could not be called: " + e.getMessage());
        } finally {
            afterInvoke.run();
        }
    }

    // MARK: - Result nodes

    /**
     * The shape the panel shows: {@code name} (for a child), {@code type}, {@code value}, the
     * {@code expression} that reaches it again, {@code hasChildren}, and, when asked for, the
     * {@code children} one level down.
     */
    private Map<String, Object> node(String name, Value value, String expression, boolean withChildren) {
        Map<String, Object> node = new LinkedHashMap<>();
        if (name != null) node.put("name", name);
        node.put("type", value == null ? "null" : value.type().name());
        node.put("value", display(value));
        node.put("expression", expression);
        boolean expandable = hasChildren(value);
        node.put("hasChildren", expandable);
        if (withChildren && expandable) node.put("children", children(value, expression));
        return node;
    }

    private List<Map<String, Object>> children(Value value, String expression) {
        List<Map<String, Object>> children = new ArrayList<>();
        if (value instanceof ArrayReference array) {
            int count = Math.min(array.length(), MAX_CHILDREN);
            List<Value> values = array.getValues(0, count);
            for (int i = 0; i < count; i++) {
                children.add(node("[" + i + "]", values.get(i), expression + "[" + i + "]", false));
            }
            if (array.length() > count) children.add(more(array.length() - count));
        } else if (value instanceof ObjectReference object) {
            int shown = 0;
            int skipped = 0;
            for (Field field : object.referenceType().allFields()) {
                if (field.isStatic() || field.isSynthetic()) continue;
                if (shown == MAX_CHILDREN) {
                    skipped++;
                    continue;
                }
                shown++;
                children.add(node(field.name(), object.getValue(field), expression + "." + field.name(), false));
            }
            if (skipped > 0) children.add(more(skipped));
        }
        return children;
    }

    private static Map<String, Object> more(int count) {
        Map<String, Object> node = new LinkedHashMap<>();
        node.put("name", "…");
        node.put("type", "");
        node.put("value", count + " more");
        node.put("expression", "");
        node.put("hasChildren", false);
        return node;
    }

    private boolean hasChildren(Value value) {
        if (value instanceof ArrayReference array) return array.length() > 0;
        if (!(value instanceof ObjectReference object) || value instanceof StringReference || isBoxOrEnum(object)) return false;
        for (Field field : object.referenceType().allFields()) {
            if (!field.isStatic() && !field.isSynthetic()) return true;
        }
        return false;
    }

    private static boolean isBoxOrEnum(ObjectReference object) {
        ReferenceType type = object.referenceType();
        return BOXES.contains(type.name()) || (type instanceof ClassType classType && classType.isEnum());
    }

    private String display(Value value) {
        if (value == null) return "null";
        if (value instanceof StringReference string) return quote(string.value());
        if (value instanceof CharValue c) return "'" + c.value() + "'";
        if (value instanceof PrimitiveValue) return value.toString();
        if (value instanceof ArrayReference array) return arraySummary(array);
        if (value instanceof ObjectReference object) {
            ReferenceType type = object.referenceType();
            if (BOXES.contains(type.name())) {
                Field field = type.fieldByName("value");
                if (field != null) return display(object.getValue(field));
            }
            if (type instanceof ClassType classType && classType.isEnum()) {
                Field field = type.fieldByName("name");
                if (field != null && object.getValue(field) instanceof StringReference name) return name.value();
            }
            return "@" + object.uniqueID();
        }
        return value.toString();
    }

    private String arraySummary(ArrayReference array) {
        String element = array.type() instanceof ArrayType arrayType ? arrayType.componentTypeName() : "";
        int length = array.length();
        StringBuilder out = new StringBuilder(element).append('[').append(length).append("] {");
        int shown = Math.min(length, 8);
        List<Value> values = array.getValues(0, shown);
        for (int i = 0; i < shown; i++) {
            if (i > 0) out.append(", ");
            Value v = values.get(i);
            out.append(v instanceof ObjectReference && !(v instanceof StringReference) && !isBoxOrEnumSafe(v) ? "@" + ((ObjectReference) v).uniqueID() : display(v));
        }
        if (length > shown) out.append(", …");
        return out.append('}').toString();
    }

    private static boolean isBoxOrEnumSafe(Value value) {
        return value instanceof ObjectReference object && isBoxOrEnum(object);
    }

    private static String quote(String string) {
        String shown = string.length() > MAX_STRING ? string.substring(0, MAX_STRING) + "…" : string;
        return "\"" + shown.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
    }
}
