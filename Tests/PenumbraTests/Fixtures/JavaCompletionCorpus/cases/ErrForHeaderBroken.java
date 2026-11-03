//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrForHeaderBroken {
    void test(List<String> items) {
        String a = "x";
        for (String item : items {
            a./*|*/
        }
    }
}
