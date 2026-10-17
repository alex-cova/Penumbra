//! applies: synchronized
//! yields: synchronized (user) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixSynchronized {
    void test(User user, List<User> users, UserService service) {
        user.sy/*|*/
    }
}
