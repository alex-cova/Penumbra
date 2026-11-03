//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrBrokenStatementBefore {
    void test() {
        String a = "x";
        int b = ;
        a./*|*/
    }
}
