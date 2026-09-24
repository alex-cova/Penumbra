//! receiver: com.acme.model.Role
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class OverloadStrictInt {
    void test(User user, Dog dog, UserService service) {
        service.locate(3)./*|*/
    }
}
