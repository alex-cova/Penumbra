//! applies: forr
//! yields: for (int i = count - 1; i >= 0; i--) {
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixForrInt {
    void test(User user, List<User> users, UserService service) {
        int count = 3;
        count.forr/*|*/
    }
}
