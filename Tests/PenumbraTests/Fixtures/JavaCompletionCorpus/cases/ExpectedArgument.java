//! expected: java.lang.String
//! top1: id
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedArgument {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        String id = "1";
        int n = 2;
        service.findUser(/*|*/
    }
}
