//! expected: java.util.List<java.lang.String>
//! top1: names2
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedGenericListNames {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        List<User> people = null;
        List<String> names2 = null;
        List<String> result = /*|*/
    }
}
