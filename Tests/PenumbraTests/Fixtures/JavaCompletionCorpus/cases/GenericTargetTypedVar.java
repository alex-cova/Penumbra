//! receiver: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GenericTargetTypedVar {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        var list = Collections.<User>emptyList();
        list.get(0)./*|*/
    }
}
