//! receiver: java.lang.String
//! receiverType: java.lang.String
//! oracle-completion: zzProbe(); });
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncMultiLineChainCallee {
    void test(List<User> users) {
        users.stream().map(u -> u.getName()).forEach(s -> {
            s./*|*/
    }
}
