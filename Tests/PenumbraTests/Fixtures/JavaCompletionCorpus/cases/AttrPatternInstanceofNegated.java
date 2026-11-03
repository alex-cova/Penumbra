//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrPatternInstanceofNegated {
    void test(Object o) {
        if (!(o instanceof String s)) return;
        s./*|*/
    }
}
