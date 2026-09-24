//! receiver: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ScopeShadowingReceiver {
    String user;
    void test(User user) {
        user./*|*/
    }
}
