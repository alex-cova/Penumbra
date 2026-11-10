//! gap: G3
//! receiver: java.lang.Long
//! receiverType: java.lang.Long
//! contains: longValue
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapTeeingMerger {
    void test() {
        Stream.of(1, 2).collect(Collectors.teeing(Collectors.counting(), Collectors.summingInt(i -> i), (c, s) -> c))./*|*/
    }
}
