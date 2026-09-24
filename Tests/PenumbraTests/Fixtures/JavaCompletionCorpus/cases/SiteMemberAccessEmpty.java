//! site: memberAccess
//! receiver: com.acme.model.User
//! contains: getName, getAddress, getId, isActive
//! excludes: secretHelper, id, name
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class SiteMemberAccessEmpty {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        user./*|*/
    }
}
