//! target: util/Strings.java:join
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodOverloadByArity {
    String m() { return Strings./*|*/join("a", "b", "c"); }
}
