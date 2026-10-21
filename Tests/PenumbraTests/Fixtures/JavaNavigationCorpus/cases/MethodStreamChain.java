//! target: model/Animal.java:getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodStreamChain {
    List<String> m(List<Dog> dogs) { return dogs.stream().map(d -> d./*|*/getName()).toList(); }
}
