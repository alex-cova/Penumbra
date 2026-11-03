//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrYieldUnterminated {
    void test(Object o) {
        String a = "x";
        int n = switch (o) {
            case String s -> { yield s./*|*/
        };
    }
}
