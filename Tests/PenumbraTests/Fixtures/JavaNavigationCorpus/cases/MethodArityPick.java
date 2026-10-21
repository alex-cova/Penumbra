//! target: model/Dog.java:fetch
//! note: two-argument overload
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodArityPick {
    void m(Dog d, Ball b) { d./*|*/fetch(b, 2); }
}
