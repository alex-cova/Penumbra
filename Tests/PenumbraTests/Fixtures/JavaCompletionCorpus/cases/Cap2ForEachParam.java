//! receiver: java.lang.CharSequence
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap2ForEachParam {
    void test() throws Exception {
        List<? extends CharSequence> l = new ArrayList<String>(); l.forEach(c -> c./*|*/);
    }
}
