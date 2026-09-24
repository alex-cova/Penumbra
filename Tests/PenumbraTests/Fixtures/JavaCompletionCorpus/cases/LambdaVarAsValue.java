//! receiver: java.util.function.Function
//! contains: apply, andThen
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LambdaVarAsValue {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        var f = (Function<User, String>) u -> u.getName();
        f./*|*/
    }
}
