//! applies: soutv
//! yields: System.out.println("user.getName() = " + user.getName());
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixSoutv {
    void test(User user, List<User> users, UserService service) {
        user.getName().soutv/*|*/
    }
}
