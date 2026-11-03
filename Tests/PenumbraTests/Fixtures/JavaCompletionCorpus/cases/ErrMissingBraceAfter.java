//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class ErrMissingBraceAfter {
    void test() {
        String a = "x";
        a./*|*/

}
