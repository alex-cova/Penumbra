//! receiver: com.acme.model.User
//! invocation: 2
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class VisibilityPrivateSecondInvocation {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        user./*|*/
    }
}
