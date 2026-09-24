//! applies: if
//! yields: if (user.isActive()) {\n            \n        }
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixIf {
    void test(User user, List<User> users, UserService service) {
        user.isActive().if/*|*/
    }
}
