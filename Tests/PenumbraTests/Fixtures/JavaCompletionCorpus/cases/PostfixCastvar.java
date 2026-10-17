//! applies: castvar
//! yields: Object user1 = (Object) user;
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixCastvar {
    void test(User user, List<User> users, UserService service) {
        user.castv/*|*/
    }
}
