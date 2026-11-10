import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

/**
 * Hand-written receiver-type probes for the generic type system audit
 * (docs/JAVA_GENERIC_TYPE_AUDIT.md). Every access written `receiver/*P*&#47;.member` is a probe:
 * JavaReceiverTypeAuditTests replaces the member with one that does not exist, javac names the
 * receiver's type, and the engine's answer for the same site is compared with it. The file must
 * compile as it stands. Run: JAVA_AUDIT=1 JAVA_AUDIT_EXTRA=<this directory> swift test --filter JavaReceiverTypeAuditTests
 */
@SuppressWarnings({"unchecked", "rawtypes", "unused"})
final class GenericProbes {
    // ---- wildcards: ? extends T, ? super T, nested, unbounded
    static void w01(List<? extends Number> l) { l.get(0)/*P*/.intValue(); }
    static void w02(List<? super Integer> l) { l.get(0)/*P*/.toString(); }
    static void w03(Map<String, ? extends List<? extends Number>> m) { m.get("a").get(0)/*P*/.intValue(); }
    static void w04(Class<? extends Number> c) { c.getSuperclass()/*P*/.getName(); }
    static void w05(Collection<? extends Map.Entry<String, Integer>> es) { es.iterator().next().getKey()/*P*/.length(); }
    static void w06(Comparator<? super String> c) { c.reversed()/*P*/.compare("a", "b"); }
    static void w07(Supplier<? extends List<String>> s) { s.get()/*P*/.size(); }
    static void w08(Function<? super String, ? extends Number> f) { f.apply("a")/*P*/.intValue(); }
    static void w09(List<?> l) { l.get(0)/*P*/.toString(); }
    static void w10(Map<?, ? extends CharSequence> m) { m.values().iterator().next()/*P*/.length(); }
    static void w11(Optional<? extends Number> o) { o.get()/*P*/.intValue(); }
    static void w12(List<? extends List<? extends CharSequence>> l) { l.get(0).get(0)/*P*/.length(); }
    static void w13(Stream<? extends Number> s) { s.map(Number::intValue)/*P*/.findFirst(); }
    static <T> T first(List<? extends T> l) { return l.get(0); }
    static void w14(List<? extends Number> l) { first(l)/*P*/.intValue(); }
    static void w15(Map<String, List<? extends Number>> m) {
        for (Map.Entry<String, List<? extends Number>> e : m.entrySet()) { e.getValue().get(0)/*P*/.doubleValue(); }
    }
    static void w16(List<? extends CharSequence> l) { Collections.unmodifiableList(l).get(0)/*P*/.length(); }
    static void w17(Consumer<? super String> c) { c.andThen(x -> { })/*P*/.accept("a"); }
    static void w18(String s) { s.getClass()/*P*/.getName(); }
    static void w20(List<? extends Comparable<? super String>> l) { l.get(0)/*P*/.compareTo("a"); }

    // ---- nested parameterized types
    static void n01(Map<String, List<Map<Integer, Set<String>>>> m) { m.get("a").get(0).get(1).iterator().next()/*P*/.length(); }
    static void n02(Map<String, Map<String, List<Integer>>> m) { m.values().iterator().next().values().iterator().next().get(0)/*P*/.intValue(); }
    static void n03(List<Optional<List<String>>> l) { l.get(0).get().get(0)/*P*/.length(); }
    static void n04(Optional<Map.Entry<String, List<Integer>>> o) { o.get().getValue().get(0)/*P*/.intValue(); }

    // ---- generic methods, return-type inference, targets
    static <T> T id(T t) { return t; }
    static <T extends Comparable<T>> T maxOf(List<T> l) { return l.get(0); }
    static void g01(List<String> l) { Collections.max(l)/*P*/.length(); }
    static void g02(List<Integer> l) { Collections.unmodifiableList(l).get(0)/*P*/.intValue(); }
    static void g03() { Arrays.asList(1, 2.5).get(0)/*P*/.intValue(); }
    static void g04() { Stream.of(1, "a").findFirst().get()/*P*/.toString(); }
    static void g05() { List.of("a", "b").get(0)/*P*/.length(); }
    static void g06() { id("a")/*P*/.length(); }
    static void g07() { maxOf(List.of("a"))/*P*/.length(); }
    static void g08() { Map.of("a", 1).get("a")/*P*/.intValue(); }
    static void g09() { Collections.<String>emptyList().get(0)/*P*/.length(); }
    static void g10() { Optional.of("a").map(String::length).get()/*P*/.intValue(); }
    static void g11() { Optional.ofNullable((String) null).orElse("x")/*P*/.length(); }
    static void g12() { Stream.of("a").collect(Collectors.toMap(s -> s, String::length)).get("a")/*P*/.intValue(); }
    static void g13() { Stream.of("a").collect(Collectors.groupingBy(String::length)).get(1).get(0)/*P*/.length(); }
    static void g14() { Stream.of(1, 2).collect(Collectors.partitioningBy(i -> i > 1)).get(true).get(0)/*P*/.intValue(); }
    static void g15() { Stream.of("a").collect(Collectors.groupingBy(String::length, TreeMap::new, Collectors.toList())).firstEntry().getValue().get(0)/*P*/.length(); }
    static void g16(Map<String, Integer> m) { m.entrySet().stream().sorted(Map.Entry.comparingByValue()).map(Map.Entry::getKey).findFirst().get()/*P*/.length(); }
    static void g17() { Stream.of(List.of("a"), List.of("b")).flatMap(List::stream).findFirst().get()/*P*/.length(); }
    static void g18() { IntStream.range(0, 3).boxed().collect(Collectors.toList()).get(0)/*P*/.intValue(); }
    static void g19() { CompletableFuture.supplyAsync(() -> "x").thenApply(String::length).join()/*P*/.intValue(); }
    static void g20() { Stream.of(1, 2).reduce(0, Integer::sum)/*P*/.intValue(); }
    static void g21() { Comparator.comparing(String::length).thenComparing(Comparator.naturalOrder())/*P*/.compare("a", "b"); }
    static void g22() { Stream.iterate(1, i -> i + 1).limit(3).toList().get(0)/*P*/.intValue(); }
    static void g23() { Stream.of("a").toArray(String[]::new)[0]/*P*/.length(); }
    static void g24() { Stream.of("a").collect(Collectors.collectingAndThen(Collectors.toList(), l -> l)).get(0)/*P*/.length(); }
    static void g25() { Stream.of(1).collect(Collectors.groupingBy(i -> i, Collectors.mapping(String::valueOf, Collectors.toSet()))).get(1).iterator().next()/*P*/.length(); }
    static void g26() { Stream.of(1, 2).collect(Collectors.teeing(Collectors.counting(), Collectors.summingInt(i -> i), (c, s) -> c))/*P*/.intValue(); }
    static void g27() { Stream.of("a").map(s -> new AbstractMap.SimpleEntry<>(s, s.length())).findFirst().get().getValue()/*P*/.intValue(); }
    static void g28() { Stream.of("a", "b").collect(Collectors.toCollection(TreeSet::new)).first()/*P*/.length(); }
    static void g29(List<? extends Number> l) { l.stream().map(n -> n.intValue()).findFirst().get()/*P*/.intValue(); }
    static void g30() { Objects.requireNonNull(List.of("a")).get(0)/*P*/.length(); }
    static void g31() { Optional.of(List.of("a")).flatMap(l -> l.stream().findFirst()).get()/*P*/.length(); }
    static void g32() { new ArrayList<>(List.of("a")).get(0)/*P*/.length(); }

    // ---- type-variable bounds, multiple bounds, recursive bounds
    static <T extends Comparable<T>> void b01(T t) { t/*P*/.compareTo(t); }
    static <T extends Number & Comparable<T>> void b02(T t) { t/*P*/.intValue(); }
    static <E extends Enum<E>> void b03(Class<E> c) { c.getEnumConstants()[0]/*P*/.name(); }
    static <K extends Comparable<? super K>, V> void b04(TreeMap<K, V> m) { m.firstKey()/*P*/.compareTo(m.lastKey()); }
    static <T extends List<? extends Number>> void b05(T t) { t.get(0)/*P*/.intValue(); }
    static <T, R extends Collection<T>> void b06(R r) { r.iterator().next()/*P*/.toString(); }
    static <T extends Comparable<? super T>> void b07(List<T> l) { l.get(0)/*P*/.compareTo(l.get(1)); }
    static <U, T extends U> void b08(List<T> l) { l.get(0)/*P*/.toString(); }
    static <T extends CharSequence & Comparable<T>> void b09(List<T> l) { l.get(0)/*P*/.length(); }
    static <T extends Comparable<T>> void b10(List<T> l) { Collections.max(l)/*P*/.compareTo(l.get(0)); }
    static <T extends Number> void b11(Supplier<T> s) { s.get()/*P*/.doubleValue(); }
    static <A extends B, B extends CharSequence> void b12(A a) { a/*P*/.length(); }

    // ---- generic method references
    static <T> List<T> listOf(T t) { return List.of(t); }
    static void m01(List<String> l) { l.stream().map(Optional::of).findFirst().get().get()/*P*/.length(); }
    static void m02() { Function<String, List<String>> f = Collections::singletonList; f.apply("a").get(0)/*P*/.length(); }
    static void m03() { Supplier<List<String>> s = ArrayList::new; s.get().get(0)/*P*/.length(); }
    static void m04() { Stream.of("a").map(Collections::singletonList).findFirst().get().get(0)/*P*/.length(); }
    static void m05() { Stream.of("a").map(StringBuilder::new).findFirst().get()/*P*/.append(1); }
    static void m06() { Stream.of(1).map(String::valueOf).findFirst().get()/*P*/.length(); }
    static void m07(List<List<String>> l) { l.stream().map(List::size).findFirst().get()/*P*/.intValue(); }
    static void m08() { Stream.of("a").map(GenericProbes::listOf).findFirst().get().get(0)/*P*/.length(); }
    static void m09() { Stream.of("a").map(String::toUpperCase).sorted(Comparator.reverseOrder()).findFirst().get()/*P*/.length(); }
    static void m10() { Stream.of("a").map(Arrays::asList).findFirst().get().get(0)/*P*/.length(); }
    static void m11() { Stream.of("a").map(Set::of).findFirst().get().iterator().next()/*P*/.length(); }
    static void m12() { Stream.of(1).map(Object::toString).findFirst().get()/*P*/.length(); }
    static void m13() { Stream.of("a").map(Optional::ofNullable).filter(Optional::isPresent).map(Optional::get).findFirst().get()/*P*/.length(); }

    // ---- conditional and switch expressions
    static void c01(boolean f, List<String> a, List<String> b) { (f ? a : b).get(0)/*P*/.length(); }
    static void c02(boolean f) { (f ? new ArrayList<String>() : new LinkedList<String>()).get(0)/*P*/.length(); }
    static void c03(boolean f) { (f ? "a" : 1)/*P*/.toString(); }
    static void c04(boolean f) { (f ? Optional.of("a") : Optional.<String>empty()).get()/*P*/.length(); }
    static void c05(boolean f, List<? extends Number> a, List<Integer> b) { (f ? a : b).get(0)/*P*/.intValue(); }
    static void c06(boolean f) { (f ? List.of("a") : Set.of("b")).iterator().next()/*P*/.length(); }
    static void c07(int k) { var v = switch (k) { case 1 -> List.of("a"); default -> new ArrayList<String>(); }; v.get(0)/*P*/.length(); }
    static void c08(boolean f, Integer a, Long b) { (f ? (Number) a : b)/*P*/.intValue(); }

    // ---- lambdas with several return statements
    static void r01() { Optional.of("a").map(s -> { if (s.isEmpty()) return 1; return 2.5; }).get()/*P*/.intValue(); }
    static void r02() { Stream.of("a").map(s -> { if (s.isEmpty()) return new ArrayList<String>(); return new LinkedList<String>(); }).findFirst().get().get(0)/*P*/.length(); }
    static void r03() { Optional.of("a").map(s -> { if (s.isEmpty()) { return "x"; } else { return s; } }).get()/*P*/.length(); }
    static void r04() { Stream.of(1).map(i -> { if (i > 0) return Integer.valueOf(i); return null; }).findFirst().get()/*P*/.intValue(); }
    static void r05() { Stream.of(1).map(i -> i > 0 ? "a" : "b").findFirst().get()/*P*/.length(); }
    static void r06() { Stream.of("a").map(s -> s.isEmpty() ? List.of(1) : List.of(2)).findFirst().get().get(0)/*P*/.intValue(); }
    static void r07() { Stream.of("a").map(s -> { if (s.isEmpty()) return Optional.of(1); return Optional.<Integer>empty(); }).findFirst().get().get()/*P*/.intValue(); }

    // ---- diamond, var, anonymous, targets
    static void d01() { var x = new HashMap<String, List<Integer>>(); x.get("a").get(0)/*P*/.intValue(); }
    static void d02() { var l = List.of(1, 2); l.get(0)/*P*/.intValue(); }
    static void d03() { Map<String, List<String>> m = new HashMap<>(); m.computeIfAbsent("a", k -> new ArrayList<>()).get(0)/*P*/.length(); }
    static void d04() { new Object() { String s = "a"; }.s/*P*/.length(); }
    static void d05() { Map.Entry<String, Integer> e = Map.entry("a", 1); e.getKey()/*P*/.length(); }
    static void d06() { var anon = new Object() { String s = "a"; }; anon.s/*P*/.length(); }

    // ---- raw types
    static void raw01() { List raw = new ArrayList(); raw.get(0)/*P*/.toString(); }
    static void raw02() { Map raw = new HashMap(); raw.entrySet()/*P*/.iterator(); }
    static void raw03() { Class c = String.class; c.getSuperclass()/*P*/.getName(); }
    static void raw04(Comparable c) { c/*P*/.compareTo("a"); }

    // ---- generic classes: inner, inherited, nested bounds, defaults
    static class Box<T> { T v; class Inner { T get() { return v; } } }
    static class Pair<A, B> { A a; B b; <C> Pair<A, C> withB(C c) { return null; } }
    static class Node<T extends Comparable<T>> { Node<T> next; T val; }
    static class Base<T> { T item; }
    static class Derived extends Base<String> { }
    static class Holder<T extends Number> { T t; }
    interface Shape<T> { default T self() { return null; } }
    static class Sq implements Shape<String> { }
    static void i01(Box<String>.Inner in) { in.get()/*P*/.length(); }
    static void i02(Pair<String, Integer> p) { p.withB(2.5).b/*P*/.doubleValue(); }
    static void i03(Node<String> n) { n.next.val/*P*/.length(); }
    static void i04(Derived d) { d.item/*P*/.length(); }
    static void i05(Holder<? extends Integer> h) { h.t/*P*/.intValue(); }
    static void i06(Sq s) { s.self()/*P*/.length(); }

    // ---- arrays
    static void a01(List<String>[] arr) { arr[0].get(0)/*P*/.length(); }
    static <T> void a02(T[] arr) { arr/*P*/.clone(); }
    static void a03(String[][] arr) { arr[0][1]/*P*/.length(); }
    static void a04(List<String> l) { l.toArray(new String[0])[0]/*P*/.length(); }

    // ---- local classes, records and enums
    static void l01() { class Loc { String s; } new Loc().s/*P*/.length(); }
    static void l02() { record R(String x) { } new R("a").x()/*P*/.length(); }
    static void l03() { enum E { A } E.A/*P*/.name(); }
    static void l04() { class Acc { List<String> list = new ArrayList<>(); } Supplier<Acc> s = Acc::new; s.get().list/*P*/.add("a"); }

    // ---- lambda parameters
    static void p01(List<String> l) { l.forEach(s -> s/*P*/.length()); }
    static void p02(List<String> l) { l.stream().collect(Collectors.toMap(s -> s/*P*/.length(), s -> s)); }
    static void p03() { BiFunction<String, Integer, String> f = (a, b) -> a/*P*/.repeat(b); }
    static void p04(Map<String, List<Integer>> m) { m.forEach((k, v) -> v/*P*/.size()); }
    static void p05() { Stream.of(1).reduce(0, (a, b) -> a/*P*/.intValue() + b); }
    static void p06(List<? extends Number> l) { l.forEach(n -> n/*P*/.intValue()); }
    static void p07(List<? super Integer> l) { l.forEach(n -> n/*P*/.toString()); }
    static void p08(List<String> l) { l.sort((a, b) -> a/*P*/.compareTo(b)); }
    static void p09(Map<String, Integer> m) { m.entrySet().removeIf(e -> e/*P*/.getValue() > 1); }
    static void p10() { Collector.of(ArrayList<String>::new, (l, v) -> l/*P*/.add("x"), (a, b) -> a, l -> l); }
    static <T extends Comparable<T>> void p11(List<T> l) { l.stream().max((a, b) -> a/*P*/.compareTo(b)); }
    static void p12(Function<String, Function<Integer, String>> f) { f.apply("a")/*P*/.apply(1); }

    // ---- scope and declaration forms (not generics, found by the first audit run)
    static void s01(String... names) { names/*P*/.clone(); }
    static void s02() { for (StringBuilder sb = new StringBuilder(); sb.length() < 3; sb = sb/*P*/.append(1)) { } }
    interface K { String C = "x"; static int s03() { return C/*P*/.length(); } }
    static class UsesK implements K { int s04() { return C/*P*/.length(); } }
}
