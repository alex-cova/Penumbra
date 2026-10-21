//! target: model/Dog.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodMapGet {
    String m(Map<String, Dog> byName) { return byName.get("a")./*|*/speak(); }
}
