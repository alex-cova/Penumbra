//! target: model/Dog.java:Dog
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeInstanceof {
    boolean m(Animal a) { return a instanceof /*|*/Dog; }
}
