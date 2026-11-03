//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrTryBroken {
    void test() {
        String a = "x";
        try {
            System.out.println(a.length(;
        } catch (RuntimeException e) {
            a./*|*/
        }
    }
}
