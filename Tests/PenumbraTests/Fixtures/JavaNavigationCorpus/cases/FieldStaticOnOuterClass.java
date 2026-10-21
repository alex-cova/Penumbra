//! target: service/Outer.java:count
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldStaticOnOuterClass {
    int m() { return Outer./*|*/count; }
}
