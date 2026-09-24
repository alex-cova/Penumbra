//! receiver: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GenericListOf {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        var list = List.of(user);
        list.get(0)./*|*/
    }
}
