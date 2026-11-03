//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrIncompleteIfBefore {
    void test() {
        String a = "x";
        if (a.isEmpty() &&
        a./*|*/
    }
}
