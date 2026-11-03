//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrConstructorBroken {
    ErrConstructorBroken(String seed) {
        String a = seed;
        System.out.println(a.length(;
        a./*|*/
    }
}
