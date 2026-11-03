//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrUnbalancedCallThenMember {
    void test() {
        String itemKept = "x";
        System.out.println(itemKept.length(;
        itemKept./*|*/
    }
}
