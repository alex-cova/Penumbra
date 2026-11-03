//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrMethodRefMapLength {
    void test() {
        Stream.of("a").map(String::length).findFirst().get()./*|*/
    }
}
