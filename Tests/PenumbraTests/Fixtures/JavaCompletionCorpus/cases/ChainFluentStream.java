//! receiver: java.util.stream.Stream
//! contains: map, filter, collect
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ChainFluentStream {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        users.stream()
            .filter(u -> u.isActive())
            .map(User::getName)
            ./*|*/
    }
}
