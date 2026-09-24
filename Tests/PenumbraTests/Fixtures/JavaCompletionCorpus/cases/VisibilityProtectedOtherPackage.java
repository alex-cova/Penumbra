//! receiver: com.acme.model.Animal
//! excludes: breathe, species, legs, digest
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class VisibilityProtectedOtherPackage {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        animal./*|*/
    }
}
