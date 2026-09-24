//! receiver: com.acme.cases.VisibilityNestedPrivate.Inner
//! contains: secret
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class VisibilityNestedPrivate {
    static class Inner {
        private int secret;
    }
    void test(Inner inner) {
        inner./*|*/
    }
}
