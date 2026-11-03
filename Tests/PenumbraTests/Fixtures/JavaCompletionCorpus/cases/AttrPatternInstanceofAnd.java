//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrPatternInstanceofAnd {
    void test(Object o) {
        if (o instanceof String s && s./*|*/
) {}
    }
}
