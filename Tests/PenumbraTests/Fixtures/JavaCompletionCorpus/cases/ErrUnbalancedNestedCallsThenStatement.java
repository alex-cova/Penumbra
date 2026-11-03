//! contains: itemKept
package com.acme.cases;

import java.util.*;

class ErrUnbalancedNestedCallsThenStatement {
    void test() {
        String itemKept = "x";
        foo(bar(baz(itemKept.length(;
        item/*|*/
    }
}
