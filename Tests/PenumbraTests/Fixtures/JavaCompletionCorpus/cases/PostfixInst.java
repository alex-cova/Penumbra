//! applies: inst
//! yields: if (user instanceof T t) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixInst {
    void test(User user, List<User> users, UserService service) {
        user.inst/*|*/
    }
}
