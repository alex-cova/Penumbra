//! receiver: com.acme.model.Dog
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class OverloadMostSpecificSubclass {
    void test(User user, Dog dog, UserService service) {
        service.adopt(dog)./*|*/
    }
}
