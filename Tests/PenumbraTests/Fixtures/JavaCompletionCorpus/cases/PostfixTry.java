//! applies: try
//! yields: try {\n            user;\n        } catch (Exception e) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixTry {
    void test(User user, List<User> users, UserService service) {
        user.try/*|*/
    }
}
