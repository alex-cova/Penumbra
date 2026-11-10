//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamShapeSubmitBlockReturnsValue {
    void test(ExecutorService executor) {
        executor.submit(() -> { return "x"; }).get()./*|*/
    }
}
