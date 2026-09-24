//! applies: nn
//! yields: if (user.getAddress() != null) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixNotNull {
    void test(User user, List<User> users, UserService service) {
        user.getAddress().nn/*|*/
    }
}
