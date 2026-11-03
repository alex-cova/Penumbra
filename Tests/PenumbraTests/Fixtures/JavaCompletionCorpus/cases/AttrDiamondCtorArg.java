//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrDiamondCtorArg {
    void test() {
        new ArrayList<>(List.of("a")).get(0)./*|*/
    }
}
