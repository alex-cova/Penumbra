//! applies: opt
//! yields: Optional.ofNullable(user)
//! appliedImport: java.util.Optional
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;

class PostfixOptImport {
    void test(User user, UserService service) {
        user.opt/*|*/
    }
}
