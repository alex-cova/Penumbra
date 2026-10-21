//! target: model/Animal.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodAbstract {
    String m(Animal a) { return a./*|*/speak(); }
}
