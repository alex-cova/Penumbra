//! receiver: com.acme.model.Animal.Entry
//! contains: label, weight
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ScopeInheritedNestedType extends Animal {
    public String sound() { return ""; }
    void test(Entry entry) {
        entry./*|*/
    }
}
