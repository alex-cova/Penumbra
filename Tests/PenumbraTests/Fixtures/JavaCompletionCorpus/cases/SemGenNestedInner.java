//! contains: innerValue
package com.acme.cases;
class SemGenNestedInner {
    class Inner { int innerValue; }
    static class Outer2 { Inner make() { return null; } }
    void test(SemGenNestedInner o) {
        Inner i = o.new Inner();
        i.inner/*|*/
    }
}
