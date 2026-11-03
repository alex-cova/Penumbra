//! receiver: java.lang.CharSequence
//! contains: length, charAt
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrCaptureForEach {
    void test(List<? extends CharSequence> texts) {
        for (var t : texts) {
            t./*|*/
        }
    }
}
