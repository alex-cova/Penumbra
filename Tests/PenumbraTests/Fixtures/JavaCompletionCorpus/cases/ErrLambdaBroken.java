//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrLambdaBroken {
    void test(List<String> items) {
        String a = "x";
        items.forEach(it -> { int q = ; });
        a./*|*/
    }
}
