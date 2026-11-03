//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrGenericMax {
    void test() {
        Collections.max(List.of(1, 2))./*|*/
    }
}
