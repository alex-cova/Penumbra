//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamOverloadStreamOfArrayLambda {
    void test(User[] users) {
        Stream.of(users).map(u -> { u./*|*/ });
    }
}
