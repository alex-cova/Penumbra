//! target: self:outerHelper
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodBareOuter {
    void outerHelper() {}
    class Inner { void m() { /*|*/outerHelper(); } }
}
