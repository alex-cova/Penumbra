//! excludes: var, return, nn
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixNoStatementInsideExpression {
    void test(User user, List<User> users, UserService service) {
        service.register(user.va/*|*/
    }
}
