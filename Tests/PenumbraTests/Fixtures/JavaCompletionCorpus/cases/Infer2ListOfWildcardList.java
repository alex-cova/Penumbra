//! receiver: java.lang.CharSequence
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ListOfWildcardList {
    void test() throws Exception {
        List<? extends List<? extends CharSequence>> l = new ArrayList<>(); l.get(0).get(0)./*|*/
    }
}
