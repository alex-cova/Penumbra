//! gap: G2
//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapArrayConstructorReference {
    void test() {
        Stream.of("a").toArray(String[]::new)[0]./*|*/
    }
}
