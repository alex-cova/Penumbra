//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrUnclosedCallBefore {
    void test() {
        String a = "x";
        System.out.println(a.length(;
        a./*|*/
    }
}
