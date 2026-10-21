//! target: model/Animal.java:name
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldInheritedFromOuterSubclass {
    static class Puppy extends Dog { class Tail { String m() { return /*|*/name; } } }
}
