//! receiver: com.acme.cases.MethodRefThis
//! contains: handle
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MethodRefThis {
    void handle(User u) { }
    void test(List<User> users) {
        users.forEach(this::/*|*/);
    }
}
