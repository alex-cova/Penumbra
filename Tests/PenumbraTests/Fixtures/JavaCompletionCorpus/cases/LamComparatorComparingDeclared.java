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

class LamComparatorComparingDeclared {
    void test() {
        Comparator<User> c = Comparator.comparing(u -> { u./*|*/ });
    }
}
