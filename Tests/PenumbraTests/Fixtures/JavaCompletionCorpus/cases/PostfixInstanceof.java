//! applies: instanceof
//! yields: if (user instanceof T t) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixInstanceof {
    void test(User user, List<User> users, UserService service) {
        user.instanceo/*|*/
    }
}
