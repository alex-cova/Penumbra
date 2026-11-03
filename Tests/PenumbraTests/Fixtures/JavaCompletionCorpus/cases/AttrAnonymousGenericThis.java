//! contains: compare, reversed, extra
package com.acme.cases;

import java.util.*;

class AttrAnonymousGenericThis {
    void test(String label) {
        new Comparator<String>() { int extra; public int compare(String a, String b) { return 0; }
            void probe() { this./*|*/
            }
        };
    }
}
