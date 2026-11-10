//! gap: G4
//! receiver: java.lang.Number
//! receiverType: java.lang.Number
//! contains: intValue
//! oracle: javac names the capture of ? extends Number
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapConditionalWildcardLub {
    void test(boolean f, List<? extends Number> a, List<Integer> b) {
        (f ? a : b).get(0)./*|*/
    }
}
