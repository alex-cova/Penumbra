//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class InferOptionalOrElse {
    void test() {
        Optional<String> o = Optional.empty(); o.map(s -> s.trim()).orElse(null)./*|*/
    }
}
