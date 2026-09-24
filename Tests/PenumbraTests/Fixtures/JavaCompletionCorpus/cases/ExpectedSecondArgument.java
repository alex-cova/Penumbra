//! expected: java.lang.String
//! top1: message
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedSecondArgument {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        String message = "hi";
        Dog other = dog;
        service.notify(user, /*|*/
    }
}
