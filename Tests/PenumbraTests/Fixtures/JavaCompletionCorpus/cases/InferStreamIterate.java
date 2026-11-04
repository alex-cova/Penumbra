//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferStreamIterate {
    void test() {
        Stream.iterate(1, i -> i + 1).limit(3).findFirst().get()./*|*/
    }
}
