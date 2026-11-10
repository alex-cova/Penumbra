//! receiver: java.lang.StringBuilder
//! receiverType: java.lang.StringBuilder
//! oracle-completion: zzProbe()
//! contains: append
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapForUpdateVariable {
    void test() {
        for (StringBuilder sb = new StringBuilder(); sb.length() < 3; sb = sb./*|*/) { }
    }
}
