//! receiver: com.acme.model.User
//! receiverType: com.acme.model.User
//! contains: getName
//! oracle-completion: zzProbe()); } });
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class LamIncAnonymousWithLambdaInside {
    void test(List<User> users) {
        new Thread(new Runnable() { public void run() { users.forEach(u -> u./*|*/
    }
}
