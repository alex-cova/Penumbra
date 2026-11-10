import com.sun.source.tree.CompilationUnitTree;
import com.sun.source.tree.ExpressionTree;
import com.sun.source.tree.LineMap;
import com.sun.source.tree.MemberSelectTree;
import com.sun.source.tree.MethodInvocationTree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.TreePath;
import com.sun.source.util.TreePathScanner;
import com.sun.source.util.Trees;

import javax.lang.model.element.Element;
import javax.lang.model.element.ElementKind;
import javax.lang.model.element.Modifier;
import javax.lang.model.element.TypeElement;
import javax.lang.model.type.ArrayType;
import javax.lang.model.type.DeclaredType;
import javax.lang.model.type.TypeKind;
import javax.lang.model.type.TypeMirror;
import javax.lang.model.type.TypeVariable;
import javax.lang.model.util.Elements;
import javax.lang.model.util.Types;
import javax.tools.Diagnostic;
import javax.tools.DiagnosticCollector;
import javax.tools.JavaCompiler;
import javax.tools.JavaFileObject;
import javax.tools.StandardJavaFileManager;
import javax.tools.ToolProvider;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/**
 * Independent javac oracle for the receiver-type fidelity audit (docs/JAVA_RECEIVER_FIDELITY_FINAL_AUDIT.md).
 *
 * For every member access {@code receiver.name} on the requested lines it prints what javac attributes to the
 * receiver: the type as javac writes it, the erased type, the binary name and owner chain of the class that
 * type names, and the members javac makes accessible through that expression at that site (the member set completion should
 * offer). Unlike the audit's {@code zzProbe} trick it does not depend on how a diagnostic spells the type.
 *
 * Usage (plain JDK, no build):
 *   java ReceiverMemberOracle.java [-cp a.jar:b.jar] [-sourcepath dir] [-processorpath p.jar] File.java line[:receiverText] ...
 *   java ReceiverMemberOracle.java ... File.java @start:end ...    (the receiver's UTF-16 source range, as javac counts it)
 */
public final class ReceiverMemberOracle {
    public static void main(String[] args) throws Exception {
        String classpath = null, sourcepath = null, processorpath = null, file = null;
        List<String> wanted = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "-cp" -> classpath = args[++i];
                case "-sourcepath" -> sourcepath = args[++i];
                case "-processorpath" -> processorpath = args[++i];
                default -> { if (file == null) file = args[i]; else wanted.add(args[i]); }
            }
        }
        JavaCompiler compiler = ToolProvider.getSystemJavaCompiler();
        DiagnosticCollector<JavaFileObject> diagnostics = new DiagnosticCollector<>();
        StandardJavaFileManager files = compiler.getStandardFileManager(diagnostics, null, StandardCharsets.UTF_8);
        // Annotation processors (Lombok) only when given, as the project's build runs them.
        List<String> options = new ArrayList<>(List.of("-Xlint:none"));
        if (processorpath != null) { options.add("-processorpath"); options.add(processorpath); } else { options.add("-proc:none"); }
        if (classpath != null) { options.add("-cp"); options.add(classpath); }
        if (sourcepath != null) { options.add("-sourcepath"); options.add(sourcepath); }
        JavacTask task = (JavacTask) compiler.getTask(null, files, diagnostics, options, null, files.getJavaFileObjects(new File(file)));
        Iterable<? extends CompilationUnitTree> units = task.parse();
        task.analyze();
        for (Diagnostic<? extends JavaFileObject> d : diagnostics.getDiagnostics()) {
            if (d.getKind() == Diagnostic.Kind.ERROR) System.out.println("javac error line " + d.getLineNumber() + ": " + d.getMessage(null).replace('\n', ' '));
        }
        Trees trees = Trees.instance(task);
        Types types = task.getTypes();
        Elements elements = task.getElements();
        for (CompilationUnitTree unit : units) {
            LineMap lines = unit.getLineMap();
            new TreePathScanner<Void, Void>() {
                @Override
                public Void visitMemberSelect(MemberSelectTree node, Void unused) {
                    com.sun.source.tree.Tree expression = node.getExpression();
                    long start = trees.getSourcePositions().getStartPosition(unit, expression);
                    long end = trees.getSourcePositions().getEndPosition(unit, expression);
                    long line = lines.getLineNumber(start);
                    String receiver = node.getExpression().toString();
                    String at = "@" + start + ":" + end;
                    boolean match = wanted.isEmpty();
                    for (String w : wanted) {
                        if (w.startsWith("@")) { if (w.equals(at)) match = true; continue; }
                        String[] parts = w.split(":", 2);
                        if (Long.parseLong(parts[0]) == line && (parts.length == 1 || parts[1].equals(receiver))) match = true;
                    }
                    if (match) report(new TreePath(getCurrentPath(), node.getExpression()), line, receiver + " " + at, node.getIdentifier().toString(), isSuper(expression));
                    return super.visitMemberSelect(node, unused);
                }

                private void report(TreePath path, long line, String receiver, String member, boolean viaSuper) {
                    TypeMirror type = trees.getTypeMirror(path);
                    System.out.println("== line " + line + " | " + receiver + " ." + member);
                    Element exprElement = trees.getElement(path);
                    // A package select (`java.util.`) has no members. An error type is not a class:
                    // do not invent `Object`'s members for a name javac could not resolve.
                    if (exprElement != null && exprElement.getKind() == ElementKind.PACKAGE) {
                        System.out.println("   type: <package>");
                        return;
                    }
                    if (type == null || type.getKind() == TypeKind.ERROR) {
                        System.out.println("   type: <none>");
                        return;
                    }
                    System.out.println("   type:    " + type + "   (kind " + type.getKind() + ")");
                    System.out.println("   erasure: " + types.erasure(type));
                    if (type instanceof javax.lang.model.type.UnionType union) {
                        System.out.println("   union alternatives: " + union.getAlternatives());
                    }
                    TypeMirror upper = type.getKind() == TypeKind.UNION ? types.erasure(type) : type;
                    if (type instanceof TypeVariable variable) upper = variable.getUpperBound();
                    Element element = types.asElement(upper);
                    if (element instanceof TypeElement typeElement) {
                        System.out.println("   binary:  " + elements.getBinaryName(typeElement) + "   nesting " + typeElement.getNestingKind());
                        StringBuilder chain = new StringBuilder();
                        for (Element e = typeElement.getEnclosingElement(); e != null && e.getKind() != ElementKind.PACKAGE; e = e.getEnclosingElement()) {
                            String name = e instanceof TypeElement t ? elements.getBinaryName(t).toString() : e.getSimpleName().toString();
                            chain.append(" <- ").append(e.getKind()).append(' ').append(name.isEmpty() ? "<anonymous>" : name);
                        }
                        System.out.println("   owners: " + (chain.length() == 0 ? " (top level)" : chain));
                    }
                    if (type instanceof DeclaredType || type instanceof TypeVariable || type instanceof ArrayType || type.getKind() == TypeKind.UNION) {
                        Set<String> members = new TreeSet<>();
                        Set<String> staticInterface = new TreeSet<>();
                        Set<String> protectedNames = new TreeSet<>();
                        var scope = trees.getScope(path);
                        TypeMirror site = type.getKind() == TypeKind.TYPEVAR ? ((TypeVariable) type).getUpperBound()
                            : type.getKind() == TypeKind.UNION ? types.erasure(type) : type;
                        Element siteElement = site instanceof DeclaredType ? types.asElement(site) : null;
                        if (site instanceof ArrayType) {
                            // JLS 10.7: length, clone(), and Object's members other than clone.
                            members.add("length");
                            siteElement = elements.getTypeElement("java.lang.Object");
                        }
                        // `List.of` is a type receiver. `list.of`, `ArrayList.of` and `I.super.of` are not.
                        boolean typeReceiver = exprElement instanceof TypeElement && !viaSuper;
                        if (siteElement instanceof TypeElement typeElement) {
                            for (Element m : elements.getAllMembers(typeElement)) {
                                if (m.getKind() == ElementKind.CONSTRUCTOR || m.getKind() == ElementKind.STATIC_INIT || m.getKind() == ElementKind.INSTANCE_INIT) continue;
                                // A static interface method is not inherited (JLS 8.4.8). It is in scope only
                                // as `DeclaringInterface.name`, never through a subclass, an instance, or `super`.
                                boolean staticInterfaceMethod = m.getModifiers().contains(Modifier.STATIC)
                                        && m.getKind() == ElementKind.METHOD
                                        && m.getEnclosingElement().getKind().isInterface();
                                if (staticInterfaceMethod) {
                                    staticInterface.add(m.getSimpleName().toString());
                                    boolean declaredHere = siteElement.equals(m.getEnclosingElement());
                                    if (!typeReceiver || !declaredHere) continue;
                                }
                                // Record every protected name, including ones the access check then drops, so a
                                // diff that is only those names can be counted apart from a wrong member set.
                                if (m.getModifiers().contains(Modifier.PROTECTED)
                                        && !m.getKind().isClass() && !m.getKind().isInterface()) {
                                    protectedNames.add(m.getSimpleName().toString());
                                }
                                DeclaredType accessFrom = site instanceof DeclaredType d ? d : (DeclaredType) elements.getTypeElement("java.lang.Object").asType();
                                // Trees.isAccessible is not the compiler's answer inside an anonymous or local
                                // class. getScope re-attributes the enclosing `new` and stops in the body while
                                // selectSuper is still set, so every protected instance member looks legal.
                                // The opposite failure is a qualified `super`: the reconstructed scope never
                                // sets selectSuper, so a legal protected member is dropped. `super` still has
                                // to pass JLS 6.6.2.1. Private and package-private members stay on isAccessible.
                                boolean accessible = trees.isAccessible(scope, m, accessFrom);
                                if (!accessible) {
                                    boolean protectedViaSuper = viaSuper && m.getModifiers().contains(Modifier.PROTECTED);
                                    if (!protectedViaSuper) continue;
                                }
                                if (!protectedQualifierAllows(types, elements, scope, m, type, viaSuper)) continue;
                                String label = m.getSimpleName().toString();
                                if (m.getKind().isClass() || m.getKind().isInterface()) continue;
                                if (m.getKind() == ElementKind.METHOD && site instanceof DeclaredType d) {
                                    TypeMirror asMember = types.asMemberOf(d, m);
                                    label += " : " + asMember + " @" + declaringName(m);
                                } else if (m.getKind() == ElementKind.METHOD && site instanceof ArrayType) {
                                    if (label.equals("clone")) label += " : ()" + site + " @" + declaringName(m);
                                    else label += " : " + m.asType() + " @" + declaringName(m);
                                } else if (m.getKind() == ElementKind.FIELD || m.getKind() == ElementKind.ENUM_CONSTANT) {
                                    // The name stays before ` : `, so name-set comparison is unchanged.
                                    label += " : @" + declaringName(m);
                                }
                                members.add(label);
                            }
                            if (site instanceof ArrayType) members.add("clone : ()" + site);
                        }
                        if (!staticInterface.isEmpty()) {
                            System.out.println("   static-interface: " + String.join(", ", staticInterface));
                        }
                        if (!protectedNames.isEmpty()) {
                            System.out.println("   protected: " + String.join(", ", protectedNames));
                        }
                        System.out.println("   members (" + members.size() + "): " + String.join(", ", members));
                    }
                }

                @Override
                public Void visitMethodInvocation(MethodInvocationTree node, Void unused) {
                    return super.visitMethodInvocation(node, unused);
                }
            }.scan(unit, null);
        }
    }

    /** Qualified name of the type that declares `member`. The member's simple name stays in front of ` : `. */
    private static String declaringName(Element member) {
        Element owner = member.getEnclosingElement();
        if (owner instanceof TypeElement type) return type.getQualifiedName().toString();
        return owner == null ? "" : owner.getSimpleName().toString();
    }

    /** `super` and `Outer.super`. A qualified superclass is still a super selection (JLS 15.11.2). */
    private static boolean isSuper(com.sun.source.tree.Tree expression) {
        if (expression instanceof com.sun.source.tree.IdentifierTree id) return id.getName().contentEquals("super");
        if (expression instanceof MemberSelectTree select) return select.getIdentifier().contentEquals("super");
        return false;
    }

    /**
     * JLS 6.6.2.1, the check {@code Trees.isAccessible} skips when its reconstructed scope still has
     * {@code selectSuper} set. Same package, a static member, or {@code super} needs only an enclosing
     * subclass. An instance member through another expression also needs that qualifier's type to be
     * the accessing class or a subclass of it. Interfaces are not accessing classes.
     */
    private static boolean protectedQualifierAllows(
        Types types, Elements elements, com.sun.source.tree.Scope scope, Element member, TypeMirror qualifier, boolean viaSuper
    ) {
        if (!member.getModifiers().contains(Modifier.PROTECTED)) return true;
        if (member.getKind().isClass() || member.getKind().isInterface()) return true;
        if (!(member.getEnclosingElement() instanceof TypeElement declaring)) return true;
        TypeElement start = scope.getEnclosingClass();
        if (start != null && elements.getPackageOf(start).equals(elements.getPackageOf(declaring))) return true;
        boolean skipQualifier = viaSuper || member.getModifiers().contains(Modifier.STATIC);
        TypeMirror qual = qualifier;
        if (qual.getKind() == TypeKind.TYPEVAR) qual = ((TypeVariable) qual).getUpperBound();
        if (qual.getKind() == TypeKind.WILDCARD || qual.getKind() == TypeKind.UNION || qual.getKind() == TypeKind.INTERSECTION) {
            qual = types.erasure(qual);
        }
        for (TypeElement site = start; site != null; site = enclosingType(site)) {
            if (site.getKind() == ElementKind.INTERFACE || site.getKind() == ElementKind.ANNOTATION_TYPE) continue;
            if (!isErasedSubtype(types, site.asType(), declaring.asType())) continue;
            if (skipQualifier || isErasedSubtype(types, qual, site.asType())) return true;
        }
        return false;
    }

    private static TypeElement enclosingType(Element element) {
        Element current = element.getEnclosingElement();
        while (current != null && !(current instanceof TypeElement)) current = current.getEnclosingElement();
        return current instanceof TypeElement type ? type : null;
    }

    private static boolean isErasedSubtype(Types types, TypeMirror left, TypeMirror right) {
        try {
            return types.isSubtype(types.erasure(left), types.erasure(right));
        } catch (IllegalArgumentException ex) {
            return false;
        }
    }
}
