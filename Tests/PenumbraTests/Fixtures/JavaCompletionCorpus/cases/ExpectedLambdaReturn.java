//! expected: java.lang.String
//! top5: getName, getId
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedLambdaReturn {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        Function<User, String> f = u -> u.get/*|*/;
    }
}
