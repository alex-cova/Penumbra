//! applies: return
//! yields: return user.getName();
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixReturn {
    void test(User user, List<User> users, UserService service) {
        user.getName().return/*|*/
    }
}
