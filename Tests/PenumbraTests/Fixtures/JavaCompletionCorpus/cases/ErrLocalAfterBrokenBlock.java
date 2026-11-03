//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrLocalAfterBrokenBlock {
    void test() {
        for (int i = 0; i < 3; i++ {
            String a = "x";
        }
        String b = "y";
        b./*|*/
    }
}
