//! receiver: char
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2StringJoinMapToObj {
    void test() throws Exception {
        Stream.of("a").map(s -> s.toCharArray()).findFirst().get()[0]./*|*/
    }
}
