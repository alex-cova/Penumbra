//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamNestedLambdaOuterParamInInnerCall {
    void test(User[] users) {
        Stream.of(users).map(u -> Stream.of(u.getName()).map(n -> { n./*|*/ }));
    }
}
