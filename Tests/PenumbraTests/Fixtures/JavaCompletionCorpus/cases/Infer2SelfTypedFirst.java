//! receiver: com.acme.cases.Infer2SelfTypedFirst.UserBuilder
//! contains: admin
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2SelfTypedFirst {
    static class Builder<T extends Builder<T>> { T name(String n) { return null; } } static class UserBuilder extends Builder<UserBuilder> { UserBuilder admin() { return this; } }
    void test() throws Exception {
        new UserBuilder().name("x")./*|*/
    }
}
