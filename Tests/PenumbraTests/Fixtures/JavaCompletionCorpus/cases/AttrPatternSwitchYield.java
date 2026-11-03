//! gap: F14-error-recovery
//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrPatternSwitchYield {
    void test(Object o) {
        int n = switch (o) {
            case String s -> { yield s./*|*/
        };
    }
}
