//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2TernaryRefs {
    void test() throws Exception {
        boolean f = true; var v = f ? new ArrayList<String>() : new LinkedList<String>(); v.get(0)./*|*/
    }
}
