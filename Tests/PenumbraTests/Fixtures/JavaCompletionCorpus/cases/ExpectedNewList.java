//! expected: java.util.List<com.acme.model.User>
//! top1: ArrayList
//! contains: ArrayList, LinkedList
//! excludes: HashMap
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedNewList {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        List<User> result = new /*|*/
    }
}
