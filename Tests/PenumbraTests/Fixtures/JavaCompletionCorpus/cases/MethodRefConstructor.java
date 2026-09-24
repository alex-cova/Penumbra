//! receiver: java.util.ArrayList
//! contains: new
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MethodRefConstructor {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        Supplier<List<User>> s = ArrayList::/*|*/;
    }
}
