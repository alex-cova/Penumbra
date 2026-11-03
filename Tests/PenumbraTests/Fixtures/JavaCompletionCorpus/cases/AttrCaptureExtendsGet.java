//! receiver: java.lang.Number
//! contains: intValue, doubleValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrCaptureExtendsGet {
    void test(List<? extends Number> nums) {
        nums.get(0)./*|*/
    }
}
