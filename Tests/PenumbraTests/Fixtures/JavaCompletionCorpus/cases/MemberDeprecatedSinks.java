//! receiver: com.acme.model.User
//! top5: getName, getId, getAddress, getRoles, getAge
//! excludes_top5: getLegacyName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MemberDeprecatedSinks {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        user.get/*|*/
    }
}
