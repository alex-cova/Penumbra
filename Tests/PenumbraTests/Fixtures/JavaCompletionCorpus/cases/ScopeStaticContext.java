//! excludes: instanceField, instanceMethod
//! contains: staticField
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ScopeStaticContext {
    int instanceField;
    static int staticField;
    void instanceMethod() { }
    static void test() {
        /*|*/
    }
}
