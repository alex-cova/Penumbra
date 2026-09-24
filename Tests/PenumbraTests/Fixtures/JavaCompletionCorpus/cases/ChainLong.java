//! receiver: com.acme.model.Country
//! contains: code, isEu
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ChainLong {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        service.findUser("1").getAddress().getCountry()./*|*/
    }
}
