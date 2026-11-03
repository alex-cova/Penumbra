//! contains: run, innerOnly
//! excludes: outerOnly
package com.acme.cases;

import java.util.*;

class AttrAnonymousNested {
    void test(String label) {
        new Object() { int outerOnly; Object inner = new Runnable() { int innerOnly; public void run() {
            this./*|*/
        } }; };
    }
}
