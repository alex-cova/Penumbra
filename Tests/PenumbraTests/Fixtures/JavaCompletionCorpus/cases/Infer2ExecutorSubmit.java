//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ExecutorSubmit {
    void test() throws Exception {
        ExecutorService ex = null; Future<String> f = ex.submit(() -> "a"); f.get()./*|*/
    }
}
