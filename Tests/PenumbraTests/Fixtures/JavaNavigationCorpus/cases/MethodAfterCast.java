//! target: model/Dog.java:fetch
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodAfterCast {
    void m(Animal a, Ball b) { ((Dog) a)./*|*/fetch(b); }
}
