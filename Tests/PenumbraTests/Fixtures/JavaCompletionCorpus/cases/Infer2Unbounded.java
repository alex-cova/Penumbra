//! receiver: java.lang.Object
//! contains: toString
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2Unbounded {
    void test() throws Exception {
        List<?> l = new ArrayList<String>(); l.get(0)./*|*/
    }
}
