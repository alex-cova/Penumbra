//! target: model/Dog.java:fetch
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class JavadocLinkOverloadByParameters {
    /** See {@link Dog#/*|*/fetch(Ball, int)}. */
    void m() {}
}
