//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2SelfTypedBuilder {
    static class Builder<T extends Builder<T>> { T name(String n) { return null; } T age(int a) { return null; } String build() { return ""; } } static class UserBuilder extends Builder<UserBuilder> { UserBuilder admin() { return this; } }
    void test() throws Exception {
        new UserBuilder().name("x").age(1).admin().build()./*|*/
    }
}
