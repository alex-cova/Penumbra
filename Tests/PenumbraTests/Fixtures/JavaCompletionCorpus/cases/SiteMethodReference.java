//! site: methodReference
//! contains: getName, getId
//! receiver: com.acme.model.User
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class SiteMethodReference {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        users.stream().map(User::/*|*/)
    }
}
