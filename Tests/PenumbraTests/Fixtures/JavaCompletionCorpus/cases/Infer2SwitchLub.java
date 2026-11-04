//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2SwitchLub {
    void test() throws Exception {
        int k = 1; var v = switch (k) { case 1 -> new ArrayList<String>(); default -> new LinkedList<String>(); }; v.get(0)./*|*/
    }
}
