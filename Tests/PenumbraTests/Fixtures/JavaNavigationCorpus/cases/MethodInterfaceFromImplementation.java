//! target: service/UserService.java:find
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodInterfaceFromImplementation {
    void m(DefaultUserService s) {}
    void n(UserService s) { s./*|*/find("1"); }
}
