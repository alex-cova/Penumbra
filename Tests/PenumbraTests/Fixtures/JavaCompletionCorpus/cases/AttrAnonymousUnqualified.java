//! contains: count, run, hashCode
package com.acme.cases;

import java.util.*;

class AttrAnonymousUnqualified {
    void test(String label) {
        new Runnable() { int count; public void run() {
            /*|*/
        } };
    }
}
