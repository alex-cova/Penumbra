//! contains: toUpperCase
package com.acme.cases;
import java.util.*;
class SemGenInheritedGenericTwoLevels {
    static class Base<A, B> { B second() { return null; } }
    static class Mid<X> extends Base<Integer, X> {}
    static class Leaf extends Mid<String> {}
    void test(Leaf l) {
        l.second().toUp/*|*/
    }
}
