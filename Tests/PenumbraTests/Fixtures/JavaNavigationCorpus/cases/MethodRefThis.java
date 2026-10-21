//! target: self:helper
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodRefThis {
    String helper(String s) { return s; }
    Function<String, String> f = this::/*|*/helper;
}
