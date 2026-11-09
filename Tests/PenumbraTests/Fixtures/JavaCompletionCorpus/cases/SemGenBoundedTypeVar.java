//! contains: length
package com.acme.cases;
class SemGenBoundedTypeVar {
    <T extends CharSequence & Comparable<T>> void test(T value) {
        value.l/*|*/
    }
}
