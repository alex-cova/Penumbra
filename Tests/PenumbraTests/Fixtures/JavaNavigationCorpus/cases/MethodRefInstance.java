//! target: model/Dog.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodRefInstance {
    Supplier<String> s(Dog d) { return d::/*|*/speak; }
}
