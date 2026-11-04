//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferTryResource {
    void test() {
        try (Scanner sc = new Scanner(System.in)) { sc.nextLine()./*|*/ } catch (Exception e) {}
    }
}
