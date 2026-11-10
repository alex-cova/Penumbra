//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamJdkSortedTwoParams {
    void test(List<User> users) {
        users.stream().sorted((a, b) -> { b./*|*/ });
    }
}
