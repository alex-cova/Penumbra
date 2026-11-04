//! receiver: java.io.Serializable
//! contains: toString
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2TwoArgsSameVar {
    static <T> T pick(T a, T b) { return a; }
    void test() throws Exception {
        pick(1, "s")./*|*/
    }
}
