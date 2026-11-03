//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrOpenBlockMemberVisible {
    void test() {
        String outer = "x";
        if (outer.isEmpty()) {
            String inner = "y";
            System.out.println(inner.length(;
            inner./*|*/
    }
}
