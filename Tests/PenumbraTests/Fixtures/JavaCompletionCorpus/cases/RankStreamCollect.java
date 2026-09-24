//! top5: collect
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.stream.*;

class RankStreamCollect {
    void test(User user, List<User> users, UserService service, Dog dog) {
        List<String> names = users.stream().map(User::getName).col/*|*/
    }
}
