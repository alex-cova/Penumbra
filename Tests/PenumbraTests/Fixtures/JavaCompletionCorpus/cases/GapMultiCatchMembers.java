//! receiver: java.lang.RuntimeException
//! receiverType: java.lang.RuntimeException
//! contains: getMessage
//! excludes: getParsedString, getErrorIndex
//! oracle: both alternatives extend RuntimeException, so the lub is RuntimeException
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapMultiCatchMembers {
    void run() { }
    void test() {
        try { run(); } catch (DateTimeParseException | NumberFormatException e) { e./*|*/ }
    }
}
