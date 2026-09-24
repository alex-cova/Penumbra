//! excludes: if, for, fori
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixNoIfOnString {
    void test(User user, List<User> users, UserService service) {
        user.getName().i/*|*/
    }
}
