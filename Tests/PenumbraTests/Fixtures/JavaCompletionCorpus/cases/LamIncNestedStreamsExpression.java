//! receiver: com.acme.model.Role
//! receiverType: com.acme.model.Role
//! contains: name
//! oracle-completion: zzProbe()));
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncNestedStreamsExpression {
    void test(List<User> users) {
        users.stream().map(u -> u.getRoles().stream().map(r -> r./*|*/
    }
}
