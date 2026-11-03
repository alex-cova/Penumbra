//! contains: outer, inner
package com.acme.cases;

import java.util.*;

class ErrOpenBlockStaysVisible {
    void test() {
        String outer = "x";
        if (outer.isEmpty()) {
            String inner = "y";
            System.out.println(inner.length(;
            /*|*/
    }
}
