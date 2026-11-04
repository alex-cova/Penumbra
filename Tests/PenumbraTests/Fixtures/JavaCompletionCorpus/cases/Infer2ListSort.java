//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ListSort {
    void test() throws Exception {
        List<String> l = new ArrayList<>(); l.sort((a, b) -> a.compareTo(b)); l.get(0)./*|*/
    }
}
