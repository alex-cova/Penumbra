//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrDiamondNested {
    void test() {
        Map<String, List<Integer>> m = new HashMap<>(); m.get("k").get(0)./*|*/
    }
}
