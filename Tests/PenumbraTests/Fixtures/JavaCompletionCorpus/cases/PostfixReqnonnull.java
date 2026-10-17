//! applies: reqnonnull
//! yields: Objects.requireNonNull(user)
//! appliedImport: none
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixReqnonnull {
    void test(User user, List<User> users, UserService service) {
        user.req/*|*/
    }
}
