//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrNextMethodBroken {
    void test() {
        String a = "x";
        a./*|*/
    }
    void other( {
        int z = ;
    }
}
