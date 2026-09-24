//! top1: user
//! contains: user
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ScopeShadowing {
    String user;
    void test(User user) {
        us/*|*/
    }
}
