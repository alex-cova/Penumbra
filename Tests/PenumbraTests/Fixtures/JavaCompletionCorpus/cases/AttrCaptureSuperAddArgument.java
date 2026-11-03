//! top1: count
package com.acme.cases;

import java.util.*;

class AttrCaptureSuperAddArgument {
    void test(List<? super Integer> sink, Integer count, String name) {
        sink.add(/*|*/
    }
}
