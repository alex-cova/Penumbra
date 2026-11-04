//! receiver: double
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2WildcardParamMethod {
    static double sum(List<? extends Number> l) { return 0; }
    void test() throws Exception {
        sum(List.of(1))./*|*/
    }
}
