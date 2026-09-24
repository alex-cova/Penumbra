//! applies: var
//! yields: Address address = user.getAddress();
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixVar {
    void test(User user, List<User> users, UserService service) {
        user.getAddress().var/*|*/
    }
}
