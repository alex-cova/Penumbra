//! applies: for
//! yields: for (String name : names) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixForArray {
    void test(User user, List<User> users, UserService service) {
        String[] names = new String[1];
        names.for/*|*/
    }
}
