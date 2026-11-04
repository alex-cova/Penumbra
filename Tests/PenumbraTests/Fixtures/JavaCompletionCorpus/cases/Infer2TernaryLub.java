//! receiver: double
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2TernaryLub {
    void test() throws Exception {
        boolean f = true; (f ? 1 : 2.5)./*|*/
    }
}
