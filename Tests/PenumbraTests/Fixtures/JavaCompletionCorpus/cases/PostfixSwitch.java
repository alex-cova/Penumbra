//! applies: switch
//! yields: switch (user.getName()) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixSwitch {
    void test(User user, List<User> users, UserService service) {
        user.getName().sw/*|*/
    }
}
