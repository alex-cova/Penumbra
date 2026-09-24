//! receiver: com.acme.model.Address
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class OverloadSubtypeObject {
    void test(User user, Dog dog, UserService service) {
        service.locate(user)./*|*/
    }
}
