//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrAnonymousVarMethodChain {
    void test(String label) {
        var o = new Object() { String name() { return ""; } };
        o.name()./*|*/
    }
}
