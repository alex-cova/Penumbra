//! receiver: com.acme.model.Address
//! contains: getCity
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ChainMultiLineComment {
    void test(User user, List<User> users, UserService service, Dog dog, Animal animal, Map<String, User> byId) {
        user // the current user
            .getAddress() /* never null */
            ./*|*/
    }
}
