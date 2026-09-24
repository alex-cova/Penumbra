//! expected: com.acme.model.User
//! top1: user
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedDeclUser {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        Dog pet = dog;
        User u = /*|*/
    }
}
