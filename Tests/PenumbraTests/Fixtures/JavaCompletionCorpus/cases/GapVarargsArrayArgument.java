//! receiver: com.acme.cases.GapVarargsArrayArgument.Sq
//! receiverType: com.acme.cases.GapVarargsArrayArgument.Sq<java.util.function.Predicate<T>>
//! contains: first
package com.acme.cases;

import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapVarargsArrayArgument {
    static class Sq<E> {
        static <T> Sq<T> seq(T[] values) { return null; }
        static <T> Sq<T> seq(Stream<? extends T> stream) { return null; }
        static <T> Sq<T> seq(Iterable<? extends T> iterable) { return null; }
        static <T> Sq<T> seq(Iterator<? extends T> iterator) { return null; }
        static <K, V> Sq<Map.Entry<K, V>> seq(Map<? extends K, ? extends V> map) { return null; }
        static <T> Sq<T> seq(Optional<? extends T> optional) { return null; }
        static <T> Sq<T> of(T value) { return null; }
        @SafeVarargs static <T> Sq<T> of(T... values) { return null; }
        E first() { return null; }
    }
    @SafeVarargs static <T> void test(Predicate<T>... predicates) {
        Sq.of(predicates)./*|*/;
    }
}
