//! receiver: com.acme.model.User
//! receiverKind: type
//! contains: anonymous, ANONYMOUS, Builder, class
//! excludes: getName, getId
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MemberStaticViaType {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        User./*|*/
    }
}
