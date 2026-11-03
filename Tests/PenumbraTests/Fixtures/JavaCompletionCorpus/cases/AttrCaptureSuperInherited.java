//! receiver: java.lang.Object
//! contains: toString, hashCode
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrCaptureSuperInherited {
    void test(ArrayList<? super Integer> sink) {
        sink.get(0)./*|*/
    }
}
