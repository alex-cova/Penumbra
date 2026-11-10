//! receiver: com.acme.model.Role
//! receiverType: com.acme.model.Role
//! oracle-completion: zzProbe();
//! contains: name
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncTailNestedAlreadyClosed {
    void test(List<User> users) {
        users.forEach(u -> { u.getRoles().forEach(r -> { r./*|*/
            System.out.println(r);
        });
        });
    }
}
