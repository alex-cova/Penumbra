//! target: service/Outer.java:Inner
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeImportedNested {
    void m() { Outer.Inner in = new Outer./*|*/Inner(); }
}
