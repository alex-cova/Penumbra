//! receiver: java.lang.Comparable
//! contains: compareTo
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap11CollectionsMaxWild {
    void test() throws Exception {
        List<? extends Comparable<String>> l = null; Collections.max(l, null)./*|*/
    }
}
