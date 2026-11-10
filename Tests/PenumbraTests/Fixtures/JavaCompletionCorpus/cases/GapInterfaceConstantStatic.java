//! receiver: java.lang.String
//! receiverType: java.lang.String
//! oracle-completion: zzProbe()
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapInterfaceConstantStatic {
    interface K { String C = "x"; static int m() { return C./*|*/; } }
    void test() {
        
    }
}
