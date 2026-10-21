//! target: util/Strings.java:Strings
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeStaticMethodOwner {
    boolean m(String s) { return /*|*/Strings.isBlank(s); }
}
