//! receiver: com.acme.model.Role
//! contains: canWrite
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LambdaNested {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        users.forEach(u -> u.getRoles().forEach(r -> r./*|*/))
    }
}
