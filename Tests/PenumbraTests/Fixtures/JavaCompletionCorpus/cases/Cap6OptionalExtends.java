//! receiver: java.lang.CharSequence
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap6OptionalExtends {
    void test() throws Exception {
        Optional<? extends CharSequence> o = Optional.empty(); o.get()./*|*/
    }
}
