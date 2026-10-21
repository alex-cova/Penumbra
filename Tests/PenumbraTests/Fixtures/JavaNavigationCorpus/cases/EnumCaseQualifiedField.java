//! target: model/Role.java:ADMIN
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class EnumCaseQualifiedField {
    int m(Role r) { switch (r) { case ADMIN: return 1; default: return Role./*|*/ADMIN.ordinal(); } }
}
