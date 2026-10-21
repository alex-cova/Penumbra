//! target: model/Dog.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodForEachVariable {
    void m(List<Dog> dogs) { for (Dog d : dogs) { d./*|*/speak(); } }
}
