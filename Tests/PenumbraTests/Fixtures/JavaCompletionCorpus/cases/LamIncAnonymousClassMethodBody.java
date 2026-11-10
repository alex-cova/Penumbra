//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! contains: getName
//! oracle-completion: zzProbe(); } });
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncAnonymousClassMethodBody {
    void test(List<User> users) {
        users.sort(new Comparator<User>() { public int compare(User a, User b) { return a./*|*/
    }
}
