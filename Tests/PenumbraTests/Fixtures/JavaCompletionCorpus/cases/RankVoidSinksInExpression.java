//! excludes_top5: setName, secretHelper
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.stream.*;

class RankVoidSinksInExpression {
    void test(User user, List<User> users, UserService service, Dog dog) {
        String n = user./*|*/
    }
}
