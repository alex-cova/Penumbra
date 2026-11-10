//! receiver: java.util.concurrent.Future
//! oracle: javac names the capture Future<CAP#1>; capture conversion is not modelled
//! contains: get
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamShapeSubmitBlockNoReturn {
    void test(ExecutorService executor) {
        executor.submit(() -> { System.out.println(); })./*|*/
    }
}
