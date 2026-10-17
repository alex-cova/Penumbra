//! applies: format
//! applyKind: snippet
//! yields: String.format(user.getName(), 
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixFormat {
    void test(User user, List<User> users, UserService service) {
        user.getName().format/*|*/
    }
}
