//! target: model/Named.java:greeting
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodAnonymousClassBody {
    String m() { return new Named() { public String name() { return "x"; } String g() { return /*|*/greeting(); } }.name(); }
}
