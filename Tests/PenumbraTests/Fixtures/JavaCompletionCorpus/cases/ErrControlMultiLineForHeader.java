//! contains: itemKept
package com.acme.cases;

import java.util.*;

class ErrControlMultiLineForHeader {
    void test() {
        String itemKept = "x";
        for (int i = 0;
             i < 3;
             i++) {
            item/*|*/
        }
    }
}
