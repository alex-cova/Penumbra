//! target: util/Strings.java:repeat
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodOverloadByType {
    String m() { return Strings./*|*/repeat('c', 2); }
}
