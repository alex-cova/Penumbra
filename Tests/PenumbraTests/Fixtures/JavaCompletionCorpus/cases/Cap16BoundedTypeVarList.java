//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap16BoundedTypeVarList {
    <T extends Number & Comparable<T>> void f(List<T> l) {
        l.get(0)./*|*/
    }
}
