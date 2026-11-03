//! contains: size, keySet, put, extra
package com.acme.cases;

import java.util.*;

class AttrAnonymousClassSuper {
    void test(String label) {
        new HashMap<String, Integer>() { int extra; void probe() {
            this./*|*/
        } };
    }
}
