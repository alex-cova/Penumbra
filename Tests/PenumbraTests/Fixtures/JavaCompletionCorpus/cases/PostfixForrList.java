//! applies: forr
//! yields: for (int i = users.size() - 1; i >= 0; i--) {\n            User user1 = users.get(i);
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixForrList {
    void test(User user, List<User> users, UserService service) {
        users.forr/*|*/
    }
}
