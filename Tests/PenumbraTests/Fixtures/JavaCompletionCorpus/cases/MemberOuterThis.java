//! receiver: com.acme.cases.MemberOuterThis
//! contains: outerField
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class MemberOuterThis {
    int outerField;
    class Inner {
        void test() {
            MemberOuterThis.this./*|*/
        }
    }
}
