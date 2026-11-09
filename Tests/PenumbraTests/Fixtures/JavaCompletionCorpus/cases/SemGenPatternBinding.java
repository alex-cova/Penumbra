//! contains: toUpperCase
package com.acme.cases;
class SemGenPatternBinding {
    void test(Object o) {
        if (o instanceof String s && s.toUp/*|*/) {}
    }
}
