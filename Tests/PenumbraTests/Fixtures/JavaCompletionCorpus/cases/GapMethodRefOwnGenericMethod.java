//! gap: G1
//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapMethodRefOwnGenericMethod {
    static <T> List<T> listOf(T t) { return List.of(t); }
    void test() {
        Stream.of("a").map(GapMethodRefOwnGenericMethod::listOf).findFirst().get().get(0)./*|*/
    }
}
