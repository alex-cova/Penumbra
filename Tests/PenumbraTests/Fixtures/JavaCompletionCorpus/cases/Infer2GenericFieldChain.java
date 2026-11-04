//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2GenericFieldChain {
    static class Box<T> { T value; } static class Pair<A, B> { Box<A> first; Box<B> second; }
    void test() throws Exception {
        Pair<String, Integer> p = null; p.second.value./*|*/
    }
}
