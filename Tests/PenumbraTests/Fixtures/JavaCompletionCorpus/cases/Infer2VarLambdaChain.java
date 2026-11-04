//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2VarLambdaChain {
    void test() throws Exception {
        var l = new ArrayList<Map<String, List<Integer>>>(); l.get(0).get("a").get(0)./*|*/
    }
}
