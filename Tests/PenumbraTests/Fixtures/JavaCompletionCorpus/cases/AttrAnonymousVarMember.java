//! contains: secret, toString
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class AttrAnonymousVarMember {
    void test() {
        var o = new Object() { int secret = 1; }; o./*|*/
    }
}
