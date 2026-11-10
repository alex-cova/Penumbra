//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! oracle-completion: zzProbe(); } }); } });
//! contains: getName
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncNestedAnonymousClasses {
    void test(List<User> users) {
        new Thread(new Runnable() { public void run() { users.sort(new Comparator<User>() { public int compare(User a, User b) { return a./*|*/
    }
}
