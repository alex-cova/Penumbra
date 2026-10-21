//! target: generic/Box.java:Box
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class CtorDiamond {
    com.acme.generic.Box<Dog> b = new com.acme.generic./*|*/Box<>();
}
