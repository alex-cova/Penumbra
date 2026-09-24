//! applies: for
//! yields: for (User user1 : users) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixFor {
    void test(User user, List<User> users, UserService service) {
        users.for/*|*/
    }
}
