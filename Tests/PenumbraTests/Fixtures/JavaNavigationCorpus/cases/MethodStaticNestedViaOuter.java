//! target: service/Outer.java:make
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodStaticNestedViaOuter {
    void m(Outer o) { o./*|*/make(); }
}
