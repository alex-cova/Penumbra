//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2InterfaceDefaultGeneric {
    interface Source<T> { T next(); default Source<T> self() { return this; } }
    void test() throws Exception {
        Source<String> s = null; s.self().next()./*|*/
    }
}
