//! contains: toUpperCase
//! excludes: intValue
package com.acme.cases;
import java.util.*;
class SemGenInheritedGeneric {
    static class Box<T> { T get() { return null; } }
    static class StringBox extends Box<String> {}
    void test(StringBox b) {
        b.get().toUp/*|*/
    }
}
