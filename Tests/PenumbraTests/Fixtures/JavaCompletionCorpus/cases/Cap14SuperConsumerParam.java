//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap14SuperConsumerParam {
    void test() throws Exception {
        Consumer<? super String> c = null; c.andThen(s -> s./*|*/);
    }
}
