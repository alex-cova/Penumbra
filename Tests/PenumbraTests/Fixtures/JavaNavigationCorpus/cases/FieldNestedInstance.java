//! target: service/Outer.java:depth
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldNestedInstance {
    int m(Outer.Inner in) { return in./*|*/depth; }
}
