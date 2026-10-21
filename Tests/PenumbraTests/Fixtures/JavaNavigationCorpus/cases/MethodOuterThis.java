//! target: self:outerHelper
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodOuterThis {
    void outerHelper() {}
    class Inner { void m() { MethodOuterThis.this./*|*/outerHelper(); } }
}
