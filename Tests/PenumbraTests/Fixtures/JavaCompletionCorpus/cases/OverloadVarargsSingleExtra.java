//! receiver: com.acme.model.Country
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class OverloadVarargsSingleExtra {
    void test(User user, Dog dog, UserService service) {
        service.locate("a", "b")./*|*/
    }
}
