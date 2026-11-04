//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferSwitchYieldDirect {
    void test() {
        int k = 1; (switch (k) { case 1 -> "a"; default -> "b"; })./*|*/
    }
}
