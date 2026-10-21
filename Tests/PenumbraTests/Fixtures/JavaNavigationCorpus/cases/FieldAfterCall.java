//! target: service/Outer.java:depth
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldAfterCall {
    int m(Outer o) { return o.make()./*|*/depth; }
}
