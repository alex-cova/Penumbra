//! receiver: java.lang.Object
//! contains: toString
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferSuperRead {
    void test() {
        List<? super Integer> l = new ArrayList<Number>(); l.get(0)./*|*/
    }
}
