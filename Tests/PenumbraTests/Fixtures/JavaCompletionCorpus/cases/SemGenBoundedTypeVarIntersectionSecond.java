//! contains: compareTo
package com.acme.cases;
class SemGenBoundedTypeVarIntersectionSecond {
    <T extends CharSequence & Comparable<T>> void test(T value) {
        value.comp/*|*/
    }
}
