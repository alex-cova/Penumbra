//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferListOfMixed {
    void test() {
        List.of(1, 2.5).get(0)./*|*/
    }
}
