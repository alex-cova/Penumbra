//! applies: not
//! yields: boolean b = !user.isActive()
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixNot {
    void test(User user, List<User> users, UserService service) {
        boolean b = user.isActive().no/*|*/
    }
}
