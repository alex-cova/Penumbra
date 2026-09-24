//! receiver: com.acme.model.User
//! contains: isActive
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LambdaAssignedPredicate {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        Predicate<User> p = u -> u.isA/*|*/;
    }
}
