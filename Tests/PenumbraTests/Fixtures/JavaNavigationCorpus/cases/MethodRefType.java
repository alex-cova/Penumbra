//! target: model/Animal.java:getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodRefType {
    Function<Dog, String> f = Dog::/*|*/getName;
}
