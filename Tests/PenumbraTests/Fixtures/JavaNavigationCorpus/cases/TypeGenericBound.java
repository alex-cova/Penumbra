//! target: model/Animal.java:Animal
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeGenericBound {
    <T extends /*|*/Animal> T pick(T t) { return t; }
}
