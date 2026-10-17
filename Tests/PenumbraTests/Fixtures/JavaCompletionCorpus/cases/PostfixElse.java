//! applies: else
//! yields: if (!user.isActive()) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixElse {
    void test(User user, List<User> users, UserService service) {
        user.isActive().el/*|*/
    }
}
