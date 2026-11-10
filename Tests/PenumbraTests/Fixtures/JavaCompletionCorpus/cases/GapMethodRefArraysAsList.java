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

class GapMethodRefArraysAsList {
    void test() {
        Stream.of("a").map(Arrays::asList).findFirst().get().get(0)./*|*/
    }
}
