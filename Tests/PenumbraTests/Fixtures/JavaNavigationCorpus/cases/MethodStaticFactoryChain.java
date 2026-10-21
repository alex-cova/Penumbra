//! target: model/User.java:getRole
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodStaticFactoryChain {
    Role m() { return User.of("x")./*|*/getRole(); }
}
