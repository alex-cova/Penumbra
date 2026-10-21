//! target: model/Dog.java:Dog
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class CtorExplicitSuper {
    static class Puppy extends Dog { Puppy() { /*|*/super("p"); } }
}
