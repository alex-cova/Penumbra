//! receiver: com.acme.model.Animal
//! contains: getSpecies
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GenericWildcardExtends {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        List<? extends Animal> pets = null;
        pets.get(0)./*|*/
    }
}
