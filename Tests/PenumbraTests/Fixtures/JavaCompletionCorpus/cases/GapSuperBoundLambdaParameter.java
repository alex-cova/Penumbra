//! gap: G5
//! contains: toString
//! excludes: intValue, doubleValue, longValue
//! oracle: javac types n as the capture of ? super Integer, whose members are Object's
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapSuperBoundLambdaParameter {
    void test(List<? super Integer> l) {
        l.forEach(n -> n./*|*/);
    }
}
