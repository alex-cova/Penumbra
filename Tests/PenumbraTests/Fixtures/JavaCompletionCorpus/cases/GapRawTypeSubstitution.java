//! gap: G6
//! receiver: java.util.Set
//! receiverType: java.util.Set
//! contains: iterator
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapRawTypeSubstitution {
    void test() {
        Map raw = new HashMap(); raw.entrySet()./*|*/
    }
}
