//! applies: field
//! yields: private User user1 = user;
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixField {
    void test(User user, List<User> users, UserService service) {
        user.field/*|*/
    }
}
