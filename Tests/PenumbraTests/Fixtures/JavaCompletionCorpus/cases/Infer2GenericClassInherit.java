//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2GenericClassInherit {
    static class Box<T> { T value; T get() { return value; } } static class StringBox extends Box<String> {}
    void test() throws Exception {
        new StringBox().get()./*|*/
    }
}
