//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2InnerOfGeneric {
    static class Outer<T> { class Inner { T get() { return null; } } Inner inner() { return null; } }
    void test() throws Exception {
        Outer<String> o = null; o.inner().get()./*|*/
    }
}
