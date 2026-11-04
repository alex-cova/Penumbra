//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferToList {
    void test() {
        Stream.of("a").filter(s -> !s.isEmpty()).toList().get(0)./*|*/
    }
}
