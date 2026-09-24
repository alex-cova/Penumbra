//! qualifiedInsert: com.acme.other.List
package com.acme.cases;

import java.util.List;
import com.acme.model.*;

class ImportClashExisting {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        Lis/*|*/
    }
}
