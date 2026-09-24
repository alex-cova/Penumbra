//! receiver: com.acme.model.User
//! contains: anonymous
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MemberStaticOnInstance {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        user.anon/*|*/
    }
}
