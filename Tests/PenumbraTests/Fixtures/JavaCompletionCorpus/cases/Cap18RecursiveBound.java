//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap18RecursiveBound {
    static <T extends Comparable<T>> T top(List<T> l) { return null; }
    void f() {
        top(new ArrayList<String>())./*|*/
    }
}
