//! receiver: nil
package com.acme.cases;

import java.util.*;

class ErrClosedBlockDoesNotLeak {
    void test() {
        { String hidden = ""; }
        System.out.println(hidden.length(;
        hidden./*|*/
    }
}
