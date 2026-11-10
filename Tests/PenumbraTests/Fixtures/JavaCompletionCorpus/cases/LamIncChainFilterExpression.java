//! receiver: java.lang.String
//! receiverType: java.lang.String
//! contains: length
//! oracle-completion: zzProbe());
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncChainFilterExpression {
    void test(List<User> users) {
        users.stream().map(u -> u.getName()).filter(s -> s./*|*/
    }
}
