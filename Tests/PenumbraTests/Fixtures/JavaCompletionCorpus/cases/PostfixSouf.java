//! applies: souf
//! yields: System.out.printf("%s", user);
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixSouf {
    void test(User user, List<User> users, UserService service) {
        user.souf/*|*/
    }
}
