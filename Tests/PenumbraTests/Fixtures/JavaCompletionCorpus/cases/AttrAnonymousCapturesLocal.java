//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrAnonymousCapturesLocal {
    void test(String label) {
        new Runnable() { public void run() {
            label./*|*/
        } };
    }
}
