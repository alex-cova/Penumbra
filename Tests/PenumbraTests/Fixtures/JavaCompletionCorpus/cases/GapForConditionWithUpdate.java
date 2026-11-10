//! receiver: java.util.Iterator
//! receiverType: java.util.Iterator<java.lang.String>
//! oracle-completion: zzProbe()
//! contains: hasNext
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapForConditionWithUpdate {
    void test() {
        int n = 0;
        for (Iterator<String> it = List.of("a").iterator(); it./*|*/; n++) { }
    }
}
