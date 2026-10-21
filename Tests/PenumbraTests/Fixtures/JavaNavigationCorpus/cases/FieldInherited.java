//! target: model/Animal.java:name
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldInherited {
    static class Puppy extends Dog { String m() { return this./*|*/name; } }
}
