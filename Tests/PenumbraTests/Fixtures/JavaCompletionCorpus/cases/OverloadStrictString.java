//! receiver: com.acme.model.User
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class OverloadStrictString {
    void test(User user, Dog dog, UserService service) {
        service.locate("a")./*|*/
    }
}
