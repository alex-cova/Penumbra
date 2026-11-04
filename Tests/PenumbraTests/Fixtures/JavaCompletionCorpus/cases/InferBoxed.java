//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferBoxed {
    void test() {
        IntStream.range(0, 3).boxed().findFirst().get()./*|*/
    }
}
