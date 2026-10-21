//! target: model/Dog.java:fetch
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodChainGeneric {
    void n(com.acme.generic.Box<Dog> b, Ball ball) { b.get()./*|*/fetch(ball); }
}
