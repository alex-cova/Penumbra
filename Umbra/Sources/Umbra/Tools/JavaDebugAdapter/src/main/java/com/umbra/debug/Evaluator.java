package com.umbra.debug;

import com.sun.jdi.*;

import java.util.*;

/**
 * Evaluates Java expressions against one frame of a suspended thread.
 *
 * <p>Two tiers. The interpreter here parses the expression and evaluates it with JDI alone:
 * locals, fields (any access), static members of loaded classes, array elements and
 * {@code length}, literals, every unary/binary/ternary operator with Java's promotion rules,
 * string concatenation, {@code instanceof}, casts, method calls with arguments (overloads picked
 * by arity and assignability, with boxing and varargs), {@code new} for objects and arrays, and
 * assignment to a local, field or element. Conditions and log expressions run here on every hit,
 * so it must stay cheap: parsed trees are cached by the caller ({@link #parse}).
 *
 * <p>What JDI cannot do on its own (lambdas, method references, anonymous classes, {@code switch}
 * expressions) throws {@link NeedsCompilation}; {@link #evaluate} then hands the expression to
 * the {@link Compiler} when there is one ({@link CompilingEvaluator}).
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

    /** The interpreter cannot evaluate this; the compiling tier may. */
    static final class NeedsCompilation extends RuntimeException {
        NeedsCompilation(String message) {
            super(message);
        }
    }

    /** The compiling tier: compiles the expression into the target and runs it. */
    interface Compiler {
        Value evaluate(String expression, ThreadReference thread, int frameIndex);
    }

    private static final int MAX_CHILDREN = 100;
    private static final int MAX_STRING = 200;
    static final Set<String> BOXES = Set.of(
            "java.lang.Integer", "java.lang.Long", "java.lang.Short", "java.lang.Byte",
            "java.lang.Character", "java.lang.Boolean", "java.lang.Float", "java.lang.Double");
    private static final Map<String, String> BOX_OF = Map.of(
            "int", "java.lang.Integer", "long", "java.lang.Long", "short", "java.lang.Short",
            "byte", "java.lang.Byte", "char", "java.lang.Character", "boolean", "java.lang.Boolean",
            "float", "java.lang.Float", "double", "java.lang.Double");
    private static final Set<String> PRIMITIVES = BOX_OF.keySet();

    private final VirtualMachine vm;
    private final ThreadReference thread;
    private final int frameIndex;
    /** Runs around a method invocation, so a breakpoint inside the invoked code cannot hang it. */
    private final Runnable beforeInvoke;
    private final Runnable afterInvoke;
    private final Map<Long, ObjectReference> pinned;
    private final Compiler compiler;
    private final Map<String, ReferenceType> classCache = new HashMap<>();

    Evaluator(VirtualMachine vm, ThreadReference thread, int frameIndex, Runnable beforeInvoke, Runnable afterInvoke) {
        this(vm, thread, frameIndex, beforeInvoke, afterInvoke, Map.of(), null);
    }

    Evaluator(VirtualMachine vm, ThreadReference thread, int frameIndex, Runnable beforeInvoke, Runnable afterInvoke,
              Map<Long, ObjectReference> pinned, Compiler compiler) {
        this.vm = vm;
        this.thread = thread;
        this.frameIndex = frameIndex;
        this.beforeInvoke = beforeInvoke;
        this.afterInvoke = afterInvoke;
        this.pinned = pinned;
        this.compiler = compiler;
    }

    /** The value of {@code expression}, as the node the panel shows (with its children, one level). */
    Map<String, Object> evaluate(String expression) {
        Value value = value(expression);
        return node(null, value, expression.trim(), true);
    }

    /** Evaluates with the interpreter, falling back to the compiling tier when it needs one. */
    Value value(String expression) {
        Node tree = parse(expression);
        return value(tree, expression);
    }

    Value value(Node tree, String source) {
        if (tree instanceof Unparsed unparsed) return compiled(source, unparsed.reason);
        try {
            return eval(tree);
        } catch (NeedsCompilation e) {
            return compiled(source, e.getMessage());
        }
    }

    private Value compiled(String expression, String reason) {
        if (compiler == null) {
            throw new EvaluationException(reason + " needs the compiling evaluator, which is not available here.");
        }
        return compiler.evaluate(expression, thread, frameIndex);
    }

    /** A condition's result: {@code true} or {@code false}, or an exception saying why not. */
    boolean condition(Node tree, String source) {
        Value value = value(tree, source);
        Object primitive = value == null ? null : unboxOrNull(value);
        if (primitive instanceof Boolean b) return b;
        throw new EvaluationException("The condition is not a boolean: it is " + (value == null ? "null" : value.type().name()) + ".");
    }

    /** A value as a log line shows it: strings unquoted, objects by their {@code toString()}. */
    String text(Value value) {
        return stringify(value);
    }

    // MARK: - Parsing

    /**
     * Parses {@code expression} into a tree to evaluate (and to cache: nothing in it depends on the
     * frame). An expression the interpreter cannot handle parses to an {@code Unparsed} node.
     */
    static Node parse(String expression) {
        String trimmed = expression == null ? "" : expression.trim();
        if (trimmed.isEmpty()) throw new EvaluationException("Enter an expression.");
        try {
            Parser parser = new Parser(Lexer.tokens(trimmed));
            Node node = parser.expression();
            parser.expectEnd();
            return node;
        } catch (NeedsCompilation e) {
            return new Unparsed(e.getMessage());
        }
    }

    interface Node {}

    private record Unparsed(String reason) implements Node {}
    private record Literal(Object value) implements Node {}
    private record Name(String name) implements Node {}
    private record This() implements Node {}
    private record Pinned(long id) implements Node {}
    private record Member(Node target, String name) implements Node {}
    private record Call(Node target, String name, List<Node> args) implements Node {}
    private record Index(Node target, Node index) implements Node {}
    private record Unary(String op, Node operand) implements Node {}
    private record Binary(String op, Node left, Node right) implements Node {}
    private record Conditional(Node test, Node then, Node otherwise) implements Node {}
    private record InstanceOf(Node operand, String type) implements Node {}
    private record Cast(String type, Node operand) implements Node {}
    private record New(String type, List<Node> args) implements Node {}
    private record NewArray(String elementType, List<Node> dimensions, int extraDimensions, List<Node> initializer) implements Node {}
    private record ArrayInit(List<Node> elements) implements Node {}
    private record Assign(Node target, Node value) implements Node {}

    private enum Kind { IDENT, NUMBER, STRING, CHAR, OP, PINNED, END }

    private record Token(Kind kind, String text, int offset) {
        boolean is(String op) {
            return (kind == Kind.OP || kind == Kind.IDENT) && text.equals(op);
        }
    }

    private static final class Lexer {
        private static final String[] OPERATORS = {
                ">>>=", "<<=", ">>=", ">>>", "...", "->", "::", "++", "--", "&&", "||", "==", "!=", "<=", ">=",
                "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
                "+", "-", "*", "/", "%", "=", "<", ">", "!", "~", "?", ":", ";", ",", ".", "(", ")", "[", "]",
                "{", "}", "&", "|", "^", "@"
        };

        static List<Token> tokens(String text) {
            List<Token> tokens = new ArrayList<>();
            int pos = 0;
            while (pos < text.length()) {
                char c = text.charAt(pos);
                if (Character.isWhitespace(c)) {
                    pos++;
                    continue;
                }
                int start = pos;
                if (Character.isJavaIdentifierStart(c)) {
                    while (pos < text.length() && Character.isJavaIdentifierPart(text.charAt(pos))) pos++;
                    tokens.add(new Token(Kind.IDENT, text.substring(start, pos), start));
                } else if (Character.isDigit(c) || (c == '.' && pos + 1 < text.length() && Character.isDigit(text.charAt(pos + 1)))) {
                    pos = number(text, pos);
                    tokens.add(new Token(Kind.NUMBER, text.substring(start, pos), start));
                } else if (c == '"') {
                    if (text.startsWith("\"\"\"", pos)) throw new NeedsCompilation("A text block");
                    StringBuilder out = new StringBuilder();
                    pos++;
                    while (pos < text.length() && text.charAt(pos) != '"') {
                        char ch = text.charAt(pos++);
                        if (ch == '\\' && pos < text.length()) ch = unescape(text.charAt(pos++));
                        out.append(ch);
                    }
                    if (pos >= text.length()) throw new EvaluationException("The string is not closed.");
                    pos++;
                    tokens.add(new Token(Kind.STRING, out.toString(), start));
                } else if (c == '\'') {
                    pos++;
                    if (pos >= text.length()) throw new EvaluationException("The character is not closed.");
                    char ch = text.charAt(pos++);
                    if (ch == '\\' && pos < text.length()) ch = unescape(text.charAt(pos++));
                    if (pos >= text.length() || text.charAt(pos) != '\'') throw new EvaluationException("The character is not closed.");
                    pos++;
                    tokens.add(new Token(Kind.CHAR, String.valueOf(ch), start));
                } else if (c == '#' && pos + 1 < text.length() && Character.isDigit(text.charAt(pos + 1))) {
                    pos++;
                    while (pos < text.length() && Character.isDigit(text.charAt(pos))) pos++;
                    tokens.add(new Token(Kind.PINNED, text.substring(start + 1, pos), start));
                } else {
                    String op = null;
                    for (String candidate : OPERATORS) {
                        if (text.startsWith(candidate, pos)) {
                            op = candidate;
                            break;
                        }
                    }
                    if (op == null) throw new EvaluationException("Cannot read '" + c + "'.");
                    pos += op.length();
                    tokens.add(new Token(Kind.OP, op, start));
                }
            }
            tokens.add(new Token(Kind.END, "", text.length()));
            return tokens;
        }

        private static int number(String text, int pos) {
            if (text.startsWith("0x", pos) || text.startsWith("0X", pos) || text.startsWith("0b", pos) || text.startsWith("0B", pos)) {
                pos += 2;
                while (pos < text.length() && (Character.isLetterOrDigit(text.charAt(pos)) || text.charAt(pos) == '_')) pos++;
                return pos;
            }
            while (pos < text.length()) {
                char c = text.charAt(pos);
                if (Character.isDigit(c) || c == '_' || c == '.') {
                    pos++;
                } else if ((c == 'e' || c == 'E') && pos + 1 < text.length()) {
                    pos++;
                    if (text.charAt(pos) == '+' || text.charAt(pos) == '-') pos++;
                } else if ("lLfFdD".indexOf(c) >= 0) {
                    return pos + 1;
                } else {
                    return pos;
                }
            }
            return pos;
        }

        private static char unescape(char c) {
            return switch (c) {
                case 'n' -> '\n';
                case 't' -> '\t';
                case 'r' -> '\r';
                case 'b' -> '\b';
                case 'f' -> '\f';
                case '0' -> '\0';
                case 's' -> ' ';
                default -> c;
            };
        }
    }

    private static final class Parser {
        private final List<Token> tokens;
        private int pos;

        Parser(List<Token> tokens) {
            this.tokens = tokens;
        }

        private Token peek() {
            return tokens.get(pos);
        }

        private Token peek(int ahead) {
            return tokens.get(Math.min(pos + ahead, tokens.size() - 1));
        }

        private Token next() {
            return tokens.get(pos++);
        }

        private boolean accept(String op) {
            if (peek().kind == Kind.OP && peek().text.equals(op)) {
                pos++;
                return true;
            }
            return false;
        }

        private void expect(String op) {
            if (!accept(op)) throw error("Expected '" + op + "'");
        }

        void expectEnd() {
            if (peek().kind != Kind.END) {
                if (peek().is(";") || peek().is("{")) throw new NeedsCompilation("A statement");
                throw error("Unexpected");
            }
        }

        private EvaluationException error(String what) {
            Token token = peek();
            return new EvaluationException(what + (token.kind == Kind.END ? " at the end." : " at '" + token.text + "'."));
        }

        Node expression() {
            Node left = conditional();
            if (peek().kind == Kind.OP) {
                String op = peek().text;
                if (op.equals("=")) {
                    next();
                    return new Assign(left, expression());
                }
                if (op.length() >= 2 && op.endsWith("=") && !op.equals("==") && !op.equals("!=") && !op.equals("<=") && !op.equals(">=")) {
                    next();
                    return new Assign(left, new Binary(op.substring(0, op.length() - 1), left, expression()));
                }
                if (op.equals("->")) throw new NeedsCompilation("A lambda");
            }
            return left;
        }

        private Node conditional() {
            Node test = binary(0);
            if (accept("?")) {
                Node then = expression();
                expect(":");
                Node otherwise = conditional();
                return new Conditional(test, then, otherwise);
            }
            return test;
        }

        private static final List<Set<String>> LEVELS = List.of(
                Set.of("||"), Set.of("&&"), Set.of("|"), Set.of("^"), Set.of("&"),
                Set.of("==", "!="), Set.of("<", ">", "<=", ">=", "instanceof"),
                Set.of("<<", ">>", ">>>"), Set.of("+", "-"), Set.of("*", "/", "%"));

        private Node binary(int level) {
            if (level == LEVELS.size()) return unary();
            Node left = binary(level + 1);
            while (true) {
                Token token = peek();
                boolean matches = (token.kind == Kind.OP || (token.kind == Kind.IDENT && token.text.equals("instanceof")))
                        && LEVELS.get(level).contains(token.text);
                if (!matches) return left;
                next();
                if (token.text.equals("instanceof")) {
                    left = new InstanceOf(left, type());
                    if (peek().kind == Kind.IDENT) next(); // a pattern variable: `o instanceof Foo f`
                } else {
                    left = new Binary(token.text, left, binary(level + 1));
                }
            }
        }

        private Node unary() {
            Token token = peek();
            if (token.kind == Kind.OP) {
                switch (token.text) {
                    case "+", "-", "!", "~" -> {
                        next();
                        // `-2147483648` and `-9223372036854775808L` only exist negated.
                        if (token.text.equals("-") && peek().kind == Kind.NUMBER) {
                            return postfix(literal("-" + next().text));
                        }
                        return new Unary(token.text, unary());
                    }
                    case "++", "--" -> throw new NeedsCompilation("An increment");
                    case "(" -> {
                        Node cast = castOrNull();
                        if (cast != null) return cast;
                    }
                    default -> {
                    }
                }
            }
            return postfix(primary());
        }

        /** `(Type) operand`, or null (with the position restored) when the parenthesis is not a cast. */
        private Node castOrNull() {
            int start = pos;
            if (isLambdaAhead()) throw new NeedsCompilation("A lambda");
            next(); // (
            if (peek().kind != Kind.IDENT) {
                pos = start;
                return null;
            }
            String type;
            try {
                type = type();
            } catch (EvaluationException e) {
                pos = start;
                return null;
            }
            if (!accept(")")) {
                pos = start;
                return null;
            }
            boolean primitive = PRIMITIVES.contains(type);
            Token after = peek();
            boolean operandFollows = switch (after.kind) {
                case IDENT, NUMBER, STRING, CHAR, PINNED -> true;
                case OP -> after.text.equals("(") || after.text.equals("!") || after.text.equals("~")
                        || (primitive && (after.text.equals("-") || after.text.equals("+")));
                default -> false;
            };
            // `(a) + b` is a parenthesized name; `(int) -x` is a cast.
            if (!operandFollows || (!primitive && !looksLikeType(type))) {
                pos = start;
                return null;
            }
            return new Cast(type, unary());
        }

        /** A reference cast needs a type-looking name: a capital, a dot, or brackets. */
        private static boolean looksLikeType(String type) {
            String simple = type.substring(type.lastIndexOf('.') + 1);
            return type.endsWith("]") || (!simple.isEmpty() && Character.isUpperCase(simple.charAt(0)));
        }

        /** `(a, b) ->` or `(int a) ->` from an opening parenthesis. */
        private boolean isLambdaAhead() {
            int depth = 0;
            for (int i = pos; i < tokens.size(); i++) {
                Token token = tokens.get(i);
                if (token.kind == Kind.END) return false;
                if (token.is("(")) depth++;
                if (token.is(")")) {
                    depth--;
                    if (depth == 0) return tokens.get(Math.min(i + 1, tokens.size() - 1)).is("->");
                }
            }
            return false;
        }

        /** A type name: `a.b.C`, with generic arguments skipped and `[]` kept. */
        private String type() {
            Token first = next();
            if (first.kind != Kind.IDENT) throw error("Expected a type");
            StringBuilder name = new StringBuilder(first.text);
            while (peek().is(".") && peek(1).kind == Kind.IDENT) {
                next();
                name.append('.').append(next().text);
            }
            if (peek().is("<")) skipTypeArguments();
            while (peek().is("[") && peek(1).is("]")) {
                next();
                next();
                name.append("[]");
            }
            return name.toString();
        }

        private void skipTypeArguments() {
            int depth = 0;
            do {
                Token token = next();
                if (token.kind == Kind.END) throw error("Unclosed type arguments");
                for (char c : token.text.toCharArray()) {
                    if (c == '<') depth++;
                    if (c == '>') depth--;
                }
            } while (depth > 0);
        }

        private Node primary() {
            Token token = next();
            switch (token.kind) {
                case NUMBER:
                    return literal(token.text);
                case STRING:
                    return new Literal(token.text);
                case CHAR:
                    return new Literal(token.text.charAt(0));
                case PINNED:
                    return new Pinned(Long.parseLong(token.text));
                case IDENT:
                    break;
                case OP:
                    if (token.text.equals("(")) {
                        Node inner = expression();
                        expect(")");
                        return inner;
                    }
                    if (token.text.equals("{")) throw new NeedsCompilation("A block");
                    pos--;
                    throw error("Unexpected");
                default:
                    pos--;
                    throw error("The expression ends too soon");
            }
            String name = token.text;
            switch (name) {
                case "true":
                    return new Literal(Boolean.TRUE);
                case "false":
                    return new Literal(Boolean.FALSE);
                case "null":
                    return new Literal(null);
                case "this":
                    return new This();
                case "super":
                    throw new NeedsCompilation("'super'");
                case "new":
                    return creator();
                case "switch":
                    throw new NeedsCompilation("A switch expression");
                default:
                    break;
            }
            if (peek().is("->")) throw new NeedsCompilation("A lambda");
            if (peek().is("(")) return new Call(null, name, arguments());
            return new Name(name);
        }

        private Node creator() {
            if (peek().is("<")) throw new NeedsCompilation("Generic constructor arguments");
            Token first = peek();
            if (first.kind != Kind.IDENT) throw error("Expected a type after 'new'");
            StringBuilder type = new StringBuilder(next().text);
            while (peek().is(".") && peek(1).kind == Kind.IDENT) {
                next();
                type.append('.').append(next().text);
            }
            if (peek().is("<")) skipTypeArguments();
            if (peek().is("[")) {
                List<Node> dimensions = new ArrayList<>();
                int extra = 0;
                while (peek().is("[")) {
                    next();
                    if (accept("]")) {
                        extra++;
                    } else {
                        if (extra > 0) throw error("Unexpected dimension");
                        dimensions.add(expression());
                        expect("]");
                    }
                }
                List<Node> initializer = null;
                if (peek().is("{")) {
                    if (!dimensions.isEmpty()) throw error("An array with a size cannot have an initializer");
                    initializer = arrayInitializer().elements;
                }
                return new NewArray(type.toString(), dimensions, extra, initializer);
            }
            List<Node> args = arguments();
            if (peek().is("{")) throw new NeedsCompilation("An anonymous class");
            return new New(type.toString(), args);
        }

        private ArrayInit arrayInitializer() {
            expect("{");
            List<Node> elements = new ArrayList<>();
            while (!accept("}")) {
                elements.add(peek().is("{") ? arrayInitializer() : expression());
                if (!accept(",")) {
                    expect("}");
                    break;
                }
            }
            return new ArrayInit(elements);
        }

        private List<Node> arguments() {
            expect("(");
            List<Node> args = new ArrayList<>();
            if (accept(")")) return args;
            do {
                args.add(expression());
            } while (accept(","));
            expect(")");
            return args;
        }

        private Node postfix(Node node) {
            while (true) {
                if (accept(".")) {
                    if (peek().is("<")) throw new NeedsCompilation("Explicit type arguments");
                    Token name = next();
                    if (name.kind != Kind.IDENT) {
                        pos--;
                        throw new EvaluationException("Expected a name after '.'.");
                    }
                    if (name.text.equals("class")) throw new NeedsCompilation("A class literal");
                    node = peek().is("(") ? new Call(node, name.text, arguments()) : new Member(node, name.text);
                } else if (accept("[")) {
                    Node index = expression();
                    expect("]");
                    node = new Index(node, index);
                } else if (peek().is("::")) {
                    throw new NeedsCompilation("A method reference");
                } else if (peek().is("++") || peek().is("--")) {
                    throw new NeedsCompilation("An increment");
                } else {
                    return node;
                }
            }
        }

        private static Node literal(String text) {
            String digits = text.replace("_", "");
            char last = Character.toLowerCase(digits.charAt(digits.length() - 1));
            try {
                boolean hex = digits.startsWith("0x") || digits.startsWith("0X") || digits.startsWith("-0x");
                boolean binary = digits.startsWith("0b") || digits.startsWith("0B") || digits.startsWith("-0b");
                if (hex || binary) {
                    boolean negative = digits.startsWith("-");
                    String body = digits.substring(negative ? 3 : 2);
                    boolean isLong = last == 'l';
                    if (isLong) body = body.substring(0, body.length() - 1);
                    long v = Long.parseUnsignedLong(body, hex ? 16 : 2);
                    if (negative) v = -v;
                    return new Literal(isLong ? (Object) v : (Object) (int) v);
                }
                if (last == 'l') return new Literal(Long.parseLong(digits.substring(0, digits.length() - 1)));
                if (last == 'f') return new Literal(Float.parseFloat(digits));
                if (last == 'd') return new Literal(Double.parseDouble(digits));
                if (digits.contains(".") || digits.contains("e") || digits.contains("E")) return new Literal(Double.parseDouble(digits));
                if (digits.length() > 1 && digits.startsWith("0") && !digits.startsWith("-")) return new Literal(Integer.parseInt(digits, 8));
                return new Literal(Integer.parseInt(digits));
            } catch (NumberFormatException e) {
                throw new EvaluationException("Not a number: " + text);
            }
        }
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

    private Value eval(Node node) {
        if (node instanceof Literal literal) return mirror(literal.value);
        if (node instanceof Name name) return variable(name.name);
        if (node instanceof This) {
            ObjectReference self = frame().thisObject();
            if (self == null) throw new EvaluationException("There is no 'this' in a static method.");
            return self;
        }
        if (node instanceof Pinned p) {
            ObjectReference object = pinned.get(p.id);
            if (object == null) throw new EvaluationException("The object #" + p.id + " is no longer available.");
            return object;
        }
        if (node instanceof Member member) return member(member);
        if (node instanceof Call call) return call(call);
        if (node instanceof Index index) return element(eval(index.target), eval(index.index));
        if (node instanceof Unary unary) return unary(unary.op, eval(unary.operand));
        if (node instanceof Binary binary) return binary(binary);
        if (node instanceof Conditional c) return truth(eval(c.test), "?:") ? eval(c.then) : eval(c.otherwise);
        if (node instanceof InstanceOf test) {
            Value value = eval(test.operand);
            if (!(value instanceof ObjectReference object)) return vm.mirrorOf(false);
            return vm.mirrorOf(isAssignable(object.referenceType(), test.type));
        }
        if (node instanceof Cast cast) return cast(cast.type, eval(cast.operand));
        if (node instanceof New n) return construct(n);
        if (node instanceof NewArray array) return newArray(array);
        if (node instanceof Assign assign) return assign(assign.target, eval(assign.value));
        if (node instanceof ArrayInit) throw new EvaluationException("An array initializer needs 'new Type[]'.");
        if (node instanceof Unparsed unparsed) throw new NeedsCompilation(unparsed.reason);
        throw new EvaluationException("Cannot evaluate this expression.");
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
        // A captured variable of an enclosing instance or lambda: `this$0.name`, `val$name`.
        if (self != null) {
            Field captured = self.referenceType().fieldByName("val$" + name);
            if (captured != null) return self.getValue(captured);
        }
        boolean noLocals = false;
        try {
            frame.visibleVariables();
        } catch (AbsentInformationException e) {
            noLocals = true;
        }
        throw new EvaluationException("Cannot find '" + name + "'." + (noLocals ? " The class was compiled without -g, so local variables are not available." : ""));
    }

    private boolean isVariable(String name) {
        StackFrame frame = frame();
        try {
            if (frame.visibleVariableByName(name) != null) return true;
        } catch (AbsentInformationException ignored) {
        }
        ObjectReference self = frame.thisObject();
        if (self != null && self.referenceType().fieldByName(name) != null) return true;
        Field field = frame.location().declaringType().fieldByName(name);
        return field != null && field.isStatic();
    }

    /** The class a name chain like `Math` or `java.util.List` denotes, when it is not a variable. */
    private ReferenceType typeOf(Node node) {
        String dotted = dotted(node);
        if (dotted == null) return null;
        String root = dotted.contains(".") ? dotted.substring(0, dotted.indexOf('.')) : dotted;
        if (isVariable(root)) return null;
        return findClass(dotted);
    }

    private static String dotted(Node node) {
        if (node instanceof Name name) return name.name;
        if (node instanceof Member member) {
            String target = dotted(member.target);
            return target == null ? null : target + "." + member.name;
        }
        return null;
    }

    private Value member(Member member) {
        ReferenceType type = typeOf(member.target);
        if (type != null) {
            if (member.name.equals("length") && type instanceof ArrayType) throw new EvaluationException("A type has no length.");
            Field field = type.fieldByName(member.name);
            if (field == null || !field.isStatic()) {
                ReferenceType nested = findClass(type.name() + "$" + member.name);
                if (nested != null) throw new EvaluationException("'" + member.name + "' is a class, not a value.");
                throw new EvaluationException(type.name() + " has no static field '" + member.name + "'.");
            }
            return type.getValue(field);
        }
        if (member.target instanceof Name name && !isVariable(name.name) && findClass(dotted(member)) != null) {
            throw new EvaluationException("'" + dotted(member) + "' is a class, not a value.");
        }
        Value receiver;
        try {
            receiver = eval(member.target);
        } catch (EvaluationException e) {
            if (member.target instanceof Name name && Character.isUpperCase(name.name.charAt(0))) {
                throw new EvaluationException("Cannot find '" + name.name + "'. No loaded class has that name.");
            }
            throw e;
        }
        if (receiver == null) throw new EvaluationException("Cannot read '" + member.name + "' of null.");
        if (receiver instanceof ArrayReference array) {
            if (member.name.equals("length")) return vm.mirrorOf(array.length());
            throw new EvaluationException("An array has no member '" + member.name + "'.");
        }
        if (!(receiver instanceof ObjectReference object)) {
            throw new EvaluationException("A " + receiver.type().name() + " has no member '" + member.name + "'.");
        }
        Field field = object.referenceType().fieldByName(member.name);
        if (field == null) throw new EvaluationException(object.referenceType().name() + " has no field '" + member.name + "'.");
        return field.isStatic() ? object.referenceType().getValue(field) : object.getValue(field);
    }

    private Value element(Value receiver, Value index) {
        if (receiver == null) throw new EvaluationException("Cannot index null.");
        if (!(receiver instanceof ArrayReference array)) throw new EvaluationException("Only arrays can be indexed.");
        int i = index(index);
        if (i < 0 || i >= array.length()) {
            throw new EvaluationException("Index " + i + " is out of bounds for length " + array.length() + ".");
        }
        return array.getValue(i);
    }

    private int index(Value value) {
        Object primitive = value == null ? null : unboxOrNull(value);
        if (primitive instanceof Integer || primitive instanceof Short || primitive instanceof Byte) return ((Number) primitive).intValue();
        if (primitive instanceof Character c) return c;
        throw new EvaluationException("An array index must be an int.");
    }

    // MARK: Calls

    private Value call(Call call) {
        List<Value> args = new ArrayList<>();
        for (Node arg : call.args) args.add(eval(arg));
        if (call.target == null) {
            // `foo(1)`: a method of `this`, else a static method of the frame's class or its outer classes.
            StackFrame frame = frame();
            ObjectReference self = frame.thisObject();
            if (self != null && !self.referenceType().methodsByName(call.name).isEmpty()) {
                return invoke(self, self.referenceType(), call.name, args);
            }
            ReferenceType declaring = frame.location().declaringType();
            for (ReferenceType type = declaring; type != null; type = outer(type)) {
                if (!type.methodsByName(call.name).isEmpty()) return invoke(null, type, call.name, args);
            }
            throw new EvaluationException("Cannot find method '" + call.name + "'.");
        }
        ReferenceType type = typeOf(call.target);
        if (type != null) return invoke(null, type, call.name, args);
        Value receiver;
        try {
            receiver = eval(call.target);
        } catch (EvaluationException e) {
            if (call.target instanceof Name name && Character.isUpperCase(name.name.charAt(0))) {
                throw new EvaluationException("Cannot find '" + name.name + "'. No loaded class has that name.");
            }
            throw e;
        }
        if (receiver == null) throw new EvaluationException("Cannot call " + call.name + "() on null.");
        if (receiver instanceof StringReference && call.name.equals("toString") && args.isEmpty()) return receiver;
        if (!(receiver instanceof ObjectReference object)) {
            Object primitive = unboxOrNull(receiver);
            ReferenceType box = primitive == null ? null : findClass(BOX_OF.get(receiver.type().name()));
            if (box == null) throw new EvaluationException("A " + receiver.type().name() + " has no methods.");
            return invoke(box(receiver), box, call.name, args);
        }
        if (object instanceof ArrayReference) {
            if (call.name.equals("clone") && args.isEmpty()) {
                throw new EvaluationException("Arrays cannot be cloned here.");
            }
            ReferenceType objectType = findClass("java.lang.Object");
            return invoke(object, objectType, call.name, args);
        }
        return invoke(object, object.referenceType(), call.name, args);
    }

    private ReferenceType outer(ReferenceType type) {
        String name = type.name();
        int dollar = name.lastIndexOf('$');
        return dollar < 0 ? null : findClass(name.substring(0, dollar));
    }

    private Value invoke(ObjectReference receiver, ReferenceType type, String name, List<Value> args) {
        List<Method> candidates = new ArrayList<>();
        for (Method method : type.methodsByName(name)) {
            if (receiver == null && !method.isStatic()) continue;
            if (method.isAbstract() && receiver == null) continue;
            candidates.add(method);
        }
        if (candidates.isEmpty()) {
            if (receiver == null && !type.methodsByName(name).isEmpty()) {
                throw new EvaluationException(name + "() is not static: call it on an object.");
            }
            throw new EvaluationException(type.name() + " has no method '" + name + "'.");
        }
        Method best = null;
        List<Value> bestArgs = null;
        int bestScore = -1;
        for (Method method : candidates) {
            ConvertedArgs converted = convertArguments(method, args);
            if (converted != null && converted.score > bestScore) {
                best = method;
                bestArgs = converted.values;
                bestScore = converted.score;
            }
        }
        if (best == null) {
            throw new EvaluationException("No " + name + "() of " + type.name() + " takes " + describe(args) + ".");
        }
        final Method method = best;
        final List<Value> values = bestArgs;
        return invoking(name, () -> {
            if (receiver != null) return receiver.invokeMethod(thread, method, values, ObjectReference.INVOKE_SINGLE_THREADED);
            if (type instanceof ClassType classType) return classType.invokeMethod(thread, method, values, ClassType.INVOKE_SINGLE_THREADED);
            if (type instanceof InterfaceType interfaceType) return interfaceType.invokeMethod(thread, method, values, ClassType.INVOKE_SINGLE_THREADED);
            throw new EvaluationException("Cannot call " + name + "() on " + type.name() + ".");
        });
    }

    private interface Invocation {
        Value run() throws Exception;
    }

    /** Runs a call into the target with breakpoints off, turning JDI's exceptions into messages. */
    private Value invoking(String what, Invocation invocation) {
        beforeInvoke.run();
        try {
            return invocation.run();
        } catch (InvocationException e) {
            ObjectReference exception = e.exception();
            String message = exceptionMessage(exception);
            throw new EvaluationException(what + "() threw " + exception.referenceType().name() + (message == null ? "." : ": " + message));
        } catch (IncompatibleThreadStateException e) {
            throw new EvaluationException("The program is not paused.");
        } catch (EvaluationException e) {
            throw e;
        } catch (Exception e) {
            throw new EvaluationException(what + "() could not be called: " + (e.getMessage() == null ? e.toString() : e.getMessage()));
        } finally {
            afterInvoke.run();
        }
    }

    /** `Throwable.detailMessage`, read as a field so reporting the exception runs no more code. */
    static String exceptionMessage(ObjectReference exception) {
        ReferenceType type = exception.referenceType();
        for (ReferenceType t = type; t != null; t = t instanceof ClassType c ? c.superclass() : null) {
            Field field = t.fieldByName("detailMessage");
            if (field != null && exception.getValue(field) instanceof StringReference s) return s.value();
        }
        return null;
    }

    private record ConvertedArgs(List<Value> values, int score) {}

    private ConvertedArgs convertArguments(Method method, List<Value> args) {
        List<String> typeNames = method.argumentTypeNames();
        int count = typeNames.size();
        ConvertedArgs fixed = count == args.size() ? convertFixed(method, typeNames, args) : null;
        if (fixed != null || !method.isVarArgs() || args.size() < count - 1) return fixed;
        // Varargs: pack the trailing arguments into an array of the last parameter's type.
        try {
            List<Type> types = method.argumentTypes();
            if (!(types.get(count - 1) instanceof ArrayType arrayType)) return null;
            List<Value> values = new ArrayList<>();
            int score = 0;
            for (int i = 0; i < count - 1; i++) {
                Converted c = convert(args.get(i), typeNames.get(i), types.get(i));
                if (c == null) return null;
                values.add(c.value);
                score += c.exact ? 2 : 1;
            }
            String component = arrayType.componentTypeName();
            Type componentType = safeComponentType(arrayType);
            List<Value> rest = new ArrayList<>();
            for (int i = count - 1; i < args.size(); i++) {
                Converted c = convert(args.get(i), component, componentType);
                if (c == null) return null;
                rest.add(c.value);
            }
            ArrayReference array = arrayType.newInstance(rest.size());
            if (!rest.isEmpty()) array.setValues(rest);
            values.add(array);
            return new ConvertedArgs(values, score);
        } catch (ClassNotLoadedException | InvalidTypeException e) {
            return null;
        }
    }

    private static Type safeComponentType(ArrayType type) {
        try {
            return type.componentType();
        } catch (ClassNotLoadedException e) {
            return null;
        }
    }

    private ConvertedArgs convertFixed(Method method, List<String> typeNames, List<Value> args) {
        List<Type> types;
        try {
            types = method.argumentTypes();
        } catch (ClassNotLoadedException e) {
            types = null;
        }
        List<Value> values = new ArrayList<>();
        int score = 0;
        for (int i = 0; i < args.size(); i++) {
            Converted c = convert(args.get(i), typeNames.get(i), types == null ? null : types.get(i));
            if (c == null) return null;
            values.add(c.value);
            score += c.exact ? 2 : 1;
        }
        return new ConvertedArgs(values, score);
    }

    private record Converted(Value value, boolean exact) {}

    /** `value` as an argument of type `typeName` (`type` when loaded), or null when it does not fit. */
    private Converted convert(Value value, String typeName, Type type) {
        if (PRIMITIVES.contains(typeName)) {
            Object primitive = value == null ? null : unboxOrNull(value);
            if (primitive == null) return null;
            String from = primitiveName(primitive);
            if (from.equals(typeName)) return new Converted(value instanceof PrimitiveValue ? value : mirror(primitive), true);
            if (!widens(from, typeName)) return null;
            return new Converted(mirror(convertPrimitive(primitive, typeName)), false);
        }
        if (value == null) return new Converted(null, false);
        if (value instanceof PrimitiveValue) {
            ObjectReference boxed = box(value);
            return isAssignable(boxed.referenceType(), typeName) ? new Converted(boxed, false) : null;
        }
        ObjectReference object = (ObjectReference) value;
        if (object.referenceType().name().equals(typeName)) return new Converted(object, true);
        if (type == null) return null; // the parameter's class isn't loaded, so no object is one
        return isAssignable(object.referenceType(), typeName) ? new Converted(object, false) : null;
    }

    private static boolean widens(String from, String to) {
        List<String> order = List.of("byte", "short", "int", "long", "float", "double");
        if (from.equals("char")) return List.of("int", "long", "float", "double").contains(to);
        if (from.equals("boolean") || to.equals("boolean") || to.equals("char")) return false;
        int f = order.indexOf(from);
        int t = order.indexOf(to);
        return f >= 0 && t >= 0 && f <= t && !(from.equals("byte") && to.equals("char"));
    }

    private static String primitiveName(Object primitive) {
        if (primitive instanceof Integer) return "int";
        if (primitive instanceof Long) return "long";
        if (primitive instanceof Double) return "double";
        if (primitive instanceof Float) return "float";
        if (primitive instanceof Short) return "short";
        if (primitive instanceof Byte) return "byte";
        if (primitive instanceof Character) return "char";
        return "boolean";
    }

    private static Object convertPrimitive(Object primitive, String to) {
        if (to.equals("boolean")) {
            if (primitive instanceof Boolean) return primitive;
            throw new EvaluationException("Cannot convert " + primitiveName(primitive) + " to boolean.");
        }
        if (primitive instanceof Boolean) throw new EvaluationException("Cannot convert boolean to " + to + ".");
        double asDouble = primitive instanceof Character c ? c : ((Number) primitive).doubleValue();
        long asLong = primitive instanceof Character c ? c : ((Number) primitive).longValue();
        boolean integral = !(primitive instanceof Double || primitive instanceof Float);
        return switch (to) {
            case "int" -> integral ? (int) asLong : (int) asDouble;
            case "long" -> integral ? asLong : (long) asDouble;
            case "short" -> integral ? (short) asLong : (short) asDouble;
            case "byte" -> integral ? (byte) asLong : (byte) asDouble;
            case "char" -> integral ? (char) asLong : (char) asDouble;
            case "float" -> integral ? (float) asLong : (float) asDouble;
            default -> integral ? (double) asLong : asDouble;
        };
    }

    private static String describe(List<Value> args) {
        if (args.isEmpty()) return "no arguments";
        StringBuilder out = new StringBuilder("(");
        for (int i = 0; i < args.size(); i++) {
            if (i > 0) out.append(", ");
            out.append(args.get(i) == null ? "null" : args.get(i).type().name());
        }
        return out.append(')').toString();
    }

    // MARK: Objects and arrays

    private Value construct(New n) {
        ReferenceType type = findClass(n.type);
        if (!(type instanceof ClassType classType)) {
            if (type == null) throw new EvaluationException("Cannot find class '" + n.type + "'.");
            throw new EvaluationException(n.type + " is not a class that can be created.");
        }
        List<Value> args = new ArrayList<>();
        for (Node arg : n.args) args.add(eval(arg));
        Method best = null;
        List<Value> bestArgs = null;
        int bestScore = -1;
        for (Method ctor : classType.methodsByName("<init>")) {
            if (!ctor.declaringType().equals(classType)) continue;
            ConvertedArgs converted = convertArguments(ctor, args);
            if (converted != null && converted.score > bestScore) {
                best = ctor;
                bestArgs = converted.values;
                bestScore = converted.score;
            }
        }
        if (best == null) throw new EvaluationException("No constructor of " + n.type + " takes " + describe(args) + ".");
        final Method ctor = best;
        final List<Value> values = bestArgs;
        return invoking("new " + n.type, () -> classType.newInstance(thread, ctor, values, ClassType.INVOKE_SINGLE_THREADED));
    }

    private Value newArray(NewArray array) {
        int depth = array.dimensions.size() + array.extraDimensions;
        String typeName = array.elementType + "[]".repeat(depth);
        ArrayType type = arrayType(typeName);
        if (array.initializer != null) return arrayFrom(type, array.initializer);
        List<Integer> sizes = new ArrayList<>();
        for (Node dimension : array.dimensions) sizes.add(index(eval(dimension)));
        return allocate(type, sizes, 0);
    }

    private ArrayReference allocate(ArrayType type, List<Integer> sizes, int level) {
        int size = sizes.get(level);
        if (size < 0) throw new EvaluationException("An array size cannot be negative.");
        ArrayReference array = type.newInstance(size);
        if (level + 1 < sizes.size()) {
            ArrayType inner = arrayType(type.componentTypeName());
            List<Value> rows = new ArrayList<>();
            for (int i = 0; i < size; i++) rows.add(allocate(inner, sizes, level + 1));
            try {
                if (!rows.isEmpty()) array.setValues(rows);
            } catch (InvalidTypeException | ClassNotLoadedException e) {
                throw new EvaluationException("Cannot fill the array: " + e.getMessage());
            }
        }
        return array;
    }

    private ArrayReference arrayFrom(ArrayType type, List<Node> elements) {
        String component = type.componentTypeName();
        Type componentType = safeComponentType(type);
        List<Value> values = new ArrayList<>();
        for (Node element : elements) {
            Value value = element instanceof ArrayInit init ? arrayFrom(arrayType(component), init.elements) : eval(element);
            Converted converted = convert(value, component, componentType);
            if (converted == null) throw new EvaluationException("A " + (value == null ? "null" : value.type().name()) + " cannot go in a " + type.name() + ".");
            values.add(converted.value);
        }
        ArrayReference array = type.newInstance(values.size());
        try {
            if (!values.isEmpty()) array.setValues(values);
        } catch (InvalidTypeException | ClassNotLoadedException e) {
            throw new EvaluationException("Cannot fill the array: " + e.getMessage());
        }
        return array;
    }

    private ArrayType arrayType(String typeName) {
        String element = typeName.substring(0, typeName.indexOf('['));
        String dims = typeName.substring(typeName.indexOf('['));
        String qualified = PRIMITIVES.contains(element) ? element : Optional.ofNullable(findClass(element)).map(ReferenceType::name)
                .orElseThrow(() -> new EvaluationException("Cannot find class '" + element + "'."));
        List<ReferenceType> types = vm.classesByName(qualified + dims);
        if (!types.isEmpty() && types.get(0) instanceof ArrayType arrayType) return arrayType;
        throw new EvaluationException("The program has not used " + qualified + dims + " yet, so it cannot be created here.");
    }

    // MARK: Assignment

    private Value assign(Node target, Value value) {
        if (target instanceof Name name) {
            StackFrame frame = frame();
            try {
                LocalVariable local = frame.visibleVariableByName(name.name);
                if (local != null) {
                    Value converted = assignable(value, local.typeName(), safeType(local));
                    frame.setValue(local, converted);
                    return converted;
                }
            } catch (AbsentInformationException ignored) {
            } catch (InvalidTypeException | ClassNotLoadedException e) {
                throw new EvaluationException("Cannot assign: " + e.getMessage());
            }
            ObjectReference self = frame.thisObject();
            ReferenceType type = self != null ? self.referenceType() : frame.location().declaringType();
            Field field = type.fieldByName(name.name);
            if (field == null) throw new EvaluationException("Cannot find '" + name.name + "'.");
            return setField(field.isStatic() ? null : self, type, field, value);
        }
        if (target instanceof Member member) {
            ReferenceType type = typeOf(member.target);
            if (type != null) {
                Field field = type.fieldByName(member.name);
                if (field == null || !field.isStatic()) throw new EvaluationException(type.name() + " has no static field '" + member.name + "'.");
                return setField(null, type, field, value);
            }
            Value receiver = eval(member.target);
            if (!(receiver instanceof ObjectReference object) || receiver instanceof ArrayReference) {
                throw new EvaluationException("Only a field of an object can be assigned.");
            }
            Field field = object.referenceType().fieldByName(member.name);
            if (field == null) throw new EvaluationException(object.referenceType().name() + " has no field '" + member.name + "'.");
            return setField(field.isStatic() ? null : object, object.referenceType(), field, value);
        }
        if (target instanceof Index index) {
            Value receiver = eval(index.target);
            if (!(receiver instanceof ArrayReference array)) throw new EvaluationException("Only arrays can be indexed.");
            int i = index(eval(index.index));
            if (i < 0 || i >= array.length()) throw new EvaluationException("Index " + i + " is out of bounds for length " + array.length() + ".");
            ArrayType type = (ArrayType) array.referenceType();
            Value converted = assignable(value, type.componentTypeName(), safeComponentType(type));
            try {
                array.setValue(i, converted);
            } catch (InvalidTypeException | ClassNotLoadedException e) {
                throw new EvaluationException("Cannot assign: " + e.getMessage());
            }
            return converted;
        }
        throw new EvaluationException("Only a variable, field or array element can be assigned.");
    }

    private static Type safeType(LocalVariable local) {
        try {
            return local.type();
        } catch (ClassNotLoadedException e) {
            return null;
        }
    }

    private Value setField(ObjectReference object, ReferenceType type, Field field, Value value) {
        Type fieldType;
        try {
            fieldType = field.type();
        } catch (ClassNotLoadedException e) {
            fieldType = null;
        }
        Value converted = assignable(value, field.typeName(), fieldType);
        try {
            if (object != null) {
                object.setValue(field, converted);
            } else if (type instanceof ClassType classType) {
                classType.setValue(field, converted);
            } else {
                throw new EvaluationException("Cannot assign a field of " + type.name() + ".");
            }
        } catch (InvalidTypeException | ClassNotLoadedException e) {
            throw new EvaluationException("Cannot assign: " + e.getMessage());
        }
        return converted;
    }

    /** Assignment conversion: like a call argument, plus narrowing a constant int to byte/short/char. */
    private Value assignable(Value value, String typeName, Type type) {
        Converted converted = convert(value, typeName, type);
        if (converted != null) return converted.value;
        if (PRIMITIVES.contains(typeName) && value != null && unboxOrNull(value) instanceof Integer i
                && (typeName.equals("byte") || typeName.equals("short") || typeName.equals("char"))) {
            return mirror(convertPrimitive(i, typeName));
        }
        throw new EvaluationException("A " + (value == null ? "null" : value.type().name()) + " cannot be assigned to a " + typeName + ".");
    }

    // MARK: Operators

    private Value unary(String op, Value value) {
        Object v = primitiveOperand(value, op);
        switch (op) {
            case "!":
                if (v instanceof Boolean b) return vm.mirrorOf(!b);
                throw new EvaluationException("'!' needs a boolean.");
            case "~":
                if (v instanceof Long l) return vm.mirrorOf(~l);
                if (isIntegral(v)) return vm.mirrorOf(~(int) asLong(v));
                throw new EvaluationException("'~' needs an integer.");
            case "-":
                if (v instanceof Double d) return vm.mirrorOf(-d);
                if (v instanceof Float f) return vm.mirrorOf(-f);
                if (v instanceof Long l) return vm.mirrorOf(-l);
                if (isNumeric(v)) return vm.mirrorOf(-(int) asLong(v));
                throw new EvaluationException("'-' needs a number.");
            default:
                if (v instanceof Double || v instanceof Float || v instanceof Long) return mirror(v);
                if (isNumeric(v)) return vm.mirrorOf((int) asLong(v));
                throw new EvaluationException("'+' needs a number.");
        }
    }

    private Value binary(Binary binary) {
        String op = binary.op;
        if (op.equals("&&") || op.equals("||")) {
            boolean left = truth(eval(binary.left), op);
            if (op.equals("&&") ? !left : left) return vm.mirrorOf(left);
            return vm.mirrorOf(truth(eval(binary.right), op));
        }
        Value left = eval(binary.left);
        Value right = eval(binary.right);
        if (op.equals("+") && (isString(left) || isString(right))) {
            return vm.mirrorOf(stringify(left) + stringify(right));
        }
        if (op.equals("==") || op.equals("!=")) {
            boolean equal = equal(left, right);
            return vm.mirrorOf(op.equals("==") == equal);
        }
        Object l = primitiveOperand(left, op);
        Object r = primitiveOperand(right, op);
        if (l instanceof Boolean a && r instanceof Boolean b) {
            return switch (op) {
                case "&" -> vm.mirrorOf(a & b);
                case "|" -> vm.mirrorOf(a | b);
                case "^" -> vm.mirrorOf(a ^ b);
                default -> throw new EvaluationException("'" + op + "' does not apply to booleans.");
            };
        }
        if (!isNumeric(l) || !isNumeric(r)) throw new EvaluationException("'" + op + "' needs numbers.");
        if (op.equals("<<") || op.equals(">>") || op.equals(">>>")) {
            if (!isIntegral(l) || !isIntegral(r)) throw new EvaluationException("'" + op + "' needs integers.");
            long distance = asLong(r);
            if (l instanceof Long a) {
                return vm.mirrorOf(switch (op) {
                    case "<<" -> a << distance;
                    case ">>" -> a >> distance;
                    default -> a >>> distance;
                });
            }
            int a = (int) asLong(l);
            return vm.mirrorOf(switch (op) {
                case "<<" -> a << distance;
                case ">>" -> a >> distance;
                default -> a >>> distance;
            });
        }
        String kind = promoted(l, r);
        switch (op) {
            case "<", ">", "<=", ">=": {
                boolean result;
                if (kind.equals("double") || kind.equals("float")) {
                    double a = asDouble(l), b = asDouble(r);
                    result = switch (op) { case "<" -> a < b; case ">" -> a > b; case "<=" -> a <= b; default -> a >= b; };
                } else {
                    long a = asLong(l), b = asLong(r);
                    result = switch (op) { case "<" -> a < b; case ">" -> a > b; case "<=" -> a <= b; default -> a >= b; };
                }
                return vm.mirrorOf(result);
            }
            default:
                break;
        }
        if ((op.equals("&") || op.equals("|") || op.equals("^")) && (!isIntegral(l) || !isIntegral(r))) {
            throw new EvaluationException("'" + op + "' needs integers or booleans.");
        }
        switch (kind) {
            case "double": {
                double a = asDouble(l), b = asDouble(r);
                return vm.mirrorOf(switch (op) {
                    case "+" -> a + b; case "-" -> a - b; case "*" -> a * b; case "/" -> a / b; case "%" -> a % b;
                    default -> throw new EvaluationException("'" + op + "' does not apply to double.");
                });
            }
            case "float": {
                float a = (float) asDouble(l), b = (float) asDouble(r);
                return vm.mirrorOf(switch (op) {
                    case "+" -> a + b; case "-" -> a - b; case "*" -> a * b; case "/" -> a / b; case "%" -> a % b;
                    default -> throw new EvaluationException("'" + op + "' does not apply to float.");
                });
            }
            case "long": {
                long a = asLong(l), b = asLong(r);
                if ((op.equals("/") || op.equals("%")) && b == 0) throw new EvaluationException("Division by zero.");
                return vm.mirrorOf(switch (op) {
                    case "+" -> a + b; case "-" -> a - b; case "*" -> a * b; case "/" -> a / b; case "%" -> a % b;
                    case "&" -> a & b; case "|" -> a | b; default -> a ^ b;
                });
            }
            default: {
                int a = (int) asLong(l), b = (int) asLong(r);
                if ((op.equals("/") || op.equals("%")) && b == 0) throw new EvaluationException("Division by zero.");
                return vm.mirrorOf(switch (op) {
                    case "+" -> a + b; case "-" -> a - b; case "*" -> a * b; case "/" -> a / b; case "%" -> a % b;
                    case "&" -> a & b; case "|" -> a | b; default -> a ^ b;
                });
            }
        }
    }

    /** Java's `==`: identity between two references, numeric or boolean equality otherwise. */
    private boolean equal(Value left, Value right) {
        boolean leftReference = left == null || (left instanceof ObjectReference);
        boolean rightReference = right == null || (right instanceof ObjectReference);
        if (leftReference && rightReference) {
            if (left == null || right == null) return left == right;
            return left.equals(right);
        }
        Object l = primitiveOperand(left, "==");
        Object r = primitiveOperand(right, "==");
        if (l instanceof Boolean a && r instanceof Boolean b) return a.equals(b);
        if (!isNumeric(l) || !isNumeric(r)) throw new EvaluationException("Cannot compare " + typeName(left) + " with " + typeName(right) + ".");
        String kind = promoted(l, r);
        return kind.equals("double") || kind.equals("float") ? asDouble(l) == asDouble(r) : asLong(l) == asLong(r);
    }

    private static String typeName(Value value) {
        return value == null ? "null" : value.type().name();
    }

    private boolean truth(Value value, String op) {
        Object v = value == null ? null : unboxOrNull(value);
        if (v instanceof Boolean b) return b;
        throw new EvaluationException("'" + op + "' needs a boolean, not " + typeName(value) + ".");
    }

    private Object primitiveOperand(Value value, String op) {
        if (value == null) throw new EvaluationException("'" + op + "' cannot use null.");
        Object v = unboxOrNull(value);
        if (v == null) throw new EvaluationException("'" + op + "' cannot use a " + value.type().name() + ".");
        return v;
    }

    private static boolean isNumeric(Object v) {
        return v instanceof Number || v instanceof Character;
    }

    private static boolean isIntegral(Object v) {
        return v instanceof Integer || v instanceof Long || v instanceof Short || v instanceof Byte || v instanceof Character;
    }

    private static long asLong(Object v) {
        return v instanceof Character c ? c : ((Number) v).longValue();
    }

    private static double asDouble(Object v) {
        return v instanceof Character c ? c : ((Number) v).doubleValue();
    }

    private static String promoted(Object l, Object r) {
        if (l instanceof Double || r instanceof Double) return "double";
        if (l instanceof Float || r instanceof Float) return "float";
        if (l instanceof Long || r instanceof Long) return "long";
        return "int";
    }

    private static boolean isString(Value value) {
        return value instanceof StringReference;
    }

    private Value cast(String typeName, Value value) {
        if (PRIMITIVES.contains(typeName)) {
            Object v = primitiveOperand(value, "(" + typeName + ")");
            return mirror(convertPrimitive(v, typeName));
        }
        if (value == null) return null;
        if (value instanceof PrimitiveValue) {
            ObjectReference boxed = box(value);
            if (isAssignable(boxed.referenceType(), typeName)) return boxed;
            throw new EvaluationException("Cannot cast " + value.type().name() + " to " + typeName + ".");
        }
        ObjectReference object = (ObjectReference) value;
        if (!isAssignable(object.referenceType(), typeName)) {
            throw new EvaluationException("Cannot cast " + object.referenceType().name() + " to " + typeName + ".");
        }
        return object;
    }

    // MARK: Types

    /** Whether `from` is `typeName` or a subtype of it. `typeName` may be simple (`List`). */
    private boolean isAssignable(ReferenceType from, String typeName) {
        String target = typeName;
        if (!target.endsWith("[]")) {
            // `List`, `Probe.Point` → the VM's `java.util.List`, `Probe$Point`.
            ReferenceType resolved = findClass(target);
            if (resolved != null) target = resolved.name();
        }
        if (target.equals("java.lang.Object")) return true;
        if (from instanceof ArrayType array) {
            if (target.equals("java.lang.Cloneable") || target.equals("java.io.Serializable")) return true;
            if (!target.endsWith("[]")) return false;
            String component = target.substring(0, target.length() - 2);
            if (array.componentTypeName().equals(component)) return true;
            Type componentType = safeComponentType(array);
            return componentType instanceof ReferenceType reference && isAssignable(reference, component);
        }
        return supertypeNames(from).contains(target);
    }

    private static Set<String> supertypeNames(ReferenceType type) {
        Set<String> names = new HashSet<>();
        names.add(type.name());
        if (type instanceof ClassType classType) {
            for (ClassType c = classType.superclass(); c != null; c = c.superclass()) names.add(c.name());
            for (InterfaceType i : classType.allInterfaces()) names.add(i.name());
        } else if (type instanceof InterfaceType interfaceType) {
            Deque<InterfaceType> queue = new ArrayDeque<>(interfaceType.superinterfaces());
            while (!queue.isEmpty()) {
                InterfaceType next = queue.pop();
                if (names.add(next.name())) queue.addAll(next.superinterfaces());
            }
            names.add("java.lang.Object");
        }
        return names;
    }

    /**
     * A loaded class by source name: fully qualified, nested (`Outer.Inner`), in `java.lang`, in the
     * frame's package or enclosing classes, or else the only loaded class with that simple name.
     */
    ReferenceType findClass(String name) {
        if (name == null) return null;
        if (classCache.containsKey(name)) return classCache.get(name);
        ReferenceType found = lookupClass(name);
        classCache.put(name, found);
        return found;
    }

    private ReferenceType lookupClass(String name) {
        List<String> candidates = new ArrayList<>();
        candidates.add(name);
        // `Outer.Inner` is `Outer$Inner` in the VM; try each split from the right.
        String nested = name;
        while (nested.contains(".")) {
            int dot = nested.lastIndexOf('.');
            nested = nested.substring(0, dot) + "$" + nested.substring(dot + 1);
            candidates.add(nested);
        }
        if (!name.contains(".")) {
            candidates.add("java.lang." + name);
            try {
                ReferenceType declaring = frame().location().declaringType();
                for (ReferenceType outer = declaring; outer != null; ) {
                    candidates.add(outer.name() + "$" + name);
                    int dollar = outer.name().lastIndexOf('$');
                    if (dollar < 0) break;
                    List<ReferenceType> enclosing = vm.classesByName(outer.name().substring(0, dollar));
                    outer = enclosing.isEmpty() ? null : enclosing.get(0);
                }
                String declaringName = declaring.name();
                int dot = declaringName.lastIndexOf('.');
                candidates.add(dot < 0 ? name : declaringName.substring(0, dot + 1) + name);
            } catch (EvaluationException ignored) {
                // No frame: only the plain candidates.
            }
        }
        for (String candidate : candidates) {
            List<ReferenceType> types = vm.classesByName(candidate);
            if (!types.isEmpty()) return types.get(0);
        }
        if (!name.contains(".")) {
            ReferenceType only = null;
            for (ReferenceType type : vm.allClasses()) {
                String n = type.name();
                if (n.endsWith("." + name) || n.endsWith("$" + name) || n.equals(name)) {
                    if (only != null && !only.name().equals(n)) return null;
                    only = type;
                }
            }
            return only;
        }
        return null;
    }

    // MARK: Values

    /** A JDI mirror of a Java value: primitives, strings, or null. */
    private Value mirror(Object value) {
        if (value == null) return null;
        if (value instanceof Integer v) return vm.mirrorOf(v);
        if (value instanceof Long v) return vm.mirrorOf(v);
        if (value instanceof Double v) return vm.mirrorOf(v);
        if (value instanceof Float v) return vm.mirrorOf(v);
        if (value instanceof Boolean v) return vm.mirrorOf(v);
        if (value instanceof Character v) return vm.mirrorOf(v);
        if (value instanceof Short v) return vm.mirrorOf(v);
        if (value instanceof Byte v) return vm.mirrorOf(v);
        if (value instanceof String v) return vm.mirrorOf(v);
        throw new EvaluationException("Cannot use " + value + " here.");
    }

    /** The Java value of a primitive or a box, or null for anything else. */
    static Object unboxOrNull(Value value) {
        if (value instanceof IntegerValue v) return v.value();
        if (value instanceof LongValue v) return v.value();
        if (value instanceof DoubleValue v) return v.value();
        if (value instanceof FloatValue v) return v.value();
        if (value instanceof BooleanValue v) return v.value();
        if (value instanceof CharValue v) return v.value();
        if (value instanceof ShortValue v) return v.value();
        if (value instanceof ByteValue v) return v.value();
        if (value instanceof ObjectReference object && BOXES.contains(object.referenceType().name())) {
            Field field = object.referenceType().fieldByName("value");
            return field == null ? null : unboxOrNull(object.getValue(field));
        }
        return null;
    }

    /** A primitive boxed in the target (`Integer.valueOf`). */
    private ObjectReference box(Value value) {
        if (value instanceof ObjectReference object) return object;
        String boxName = BOX_OF.get(value.type().name());
        ReferenceType box = boxName == null ? null : findClass(boxName);
        if (!(box instanceof ClassType classType)) throw new EvaluationException("Cannot box a " + value.type().name() + ".");
        for (Method method : classType.methodsByName("valueOf")) {
            List<String> args = method.argumentTypeNames();
            if (args.size() == 1 && args.get(0).equals(value.type().name())) {
                Value boxed = invoking("valueOf", () -> classType.invokeMethod(thread, method, List.of(value), ClassType.INVOKE_SINGLE_THREADED));
                return (ObjectReference) boxed;
            }
        }
        throw new EvaluationException("Cannot box a " + value.type().name() + ".");
    }

    /** `String.valueOf(value)` as Java would write it into a string. */
    private String stringify(Value value) {
        if (value == null) return "null";
        if (value instanceof StringReference s) return s.value();
        Object primitive = unboxOrNull(value);
        if (primitive != null) return String.valueOf(primitive);
        if (value instanceof ObjectReference object) {
            Value result = invokeToString(object);
            return result instanceof StringReference s ? s.value() : "null";
        }
        return value.toString();
    }

    private Value invokeToString(ObjectReference object) {
        List<Method> methods = object.referenceType() instanceof ArrayType
                ? Optional.ofNullable(findClass("java.lang.Object")).map(t -> t.methodsByName("toString", "()Ljava/lang/String;")).orElse(List.of())
                : object.referenceType().methodsByName("toString", "()Ljava/lang/String;");
        if (methods.isEmpty()) throw new EvaluationException(object.referenceType().name() + " has no toString().");
        return invoking("toString", () -> object.invokeMethod(thread, methods.get(0), List.of(), ObjectReference.INVOKE_SINGLE_THREADED));
    }

    // MARK: - Result nodes

    /**
     * The shape the panel shows: {@code name} (for a child), {@code type}, {@code value}, the
     * {@code expression} that reaches it again, {@code hasChildren}, and, when asked for, the
     * {@code children} one level down.
     */
    Map<String, Object> node(String name, Value value, String expression, boolean withChildren) {
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
        String receiver = needsParentheses(expression) ? "(" + expression + ")" : expression;
        if (value instanceof ArrayReference array) {
            int count = Math.min(array.length(), MAX_CHILDREN);
            List<Value> values = array.getValues(0, count);
            for (int i = 0; i < count; i++) {
                children.add(node("[" + i + "]", values.get(i), receiver + "[" + i + "]", false));
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
                children.add(node(field.name(), object.getValue(field), receiver + "." + field.name(), false));
            }
            if (skipped > 0) children.add(more(skipped));
        }
        return children;
    }

    /** `a + b` must be `(a + b).x` when opened; `a.b[0]` is fine as it is. */
    private static boolean needsParentheses(String expression) {
        for (int i = 0; i < expression.length(); i++) {
            char c = expression.charAt(i);
            if (" +-*/%<>=!&|?:^~".indexOf(c) >= 0) return true;
        }
        return false;
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

    static String display(Value value) {
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

    private static String arraySummary(ArrayReference array) {
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

    static String quote(String string) {
        String shown = string.length() > MAX_STRING ? string.substring(0, MAX_STRING) + "…" : string;
        return "\"" + shown.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + "\"";
    }
}
