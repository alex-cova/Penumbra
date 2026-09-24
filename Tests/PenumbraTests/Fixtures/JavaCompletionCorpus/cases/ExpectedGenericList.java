//! expected: java.util.List<com.acme.model.User>
//! top1: users
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedGenericList {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        List<String> names = null;
        List<User> copy = /*|*/
    }
}
