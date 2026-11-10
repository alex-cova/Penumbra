//! receiver: array
//! receiverType: java.lang.String[]
//! contains: length, clone
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapVarargsShadowsField {
    List<String> names;
    void test(String... names) {
        names./*|*/
    }
}
