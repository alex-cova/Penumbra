//! receiver: java.util.List
//! contains: add, size
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrCaptureMapValue {
    void test(Map<String, ? extends List<String>> groups) {
        groups.get("a")./*|*/
    }
}
