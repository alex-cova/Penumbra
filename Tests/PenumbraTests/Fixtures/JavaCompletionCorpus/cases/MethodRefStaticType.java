//! receiver: com.acme.util.Strings
//! contains: isBlank, capitalize
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MethodRefStaticType {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        users.stream().map(User::getName).filter(com.acme.util.Strings::/*|*/)
    }
}
