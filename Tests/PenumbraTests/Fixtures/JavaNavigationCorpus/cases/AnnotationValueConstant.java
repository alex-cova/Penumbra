//! target: util/Strings.java:EMPTY
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class AnnotationValueConstant {
    @Marker(value = Strings./*|*/EMPTY)
    void m() {}
}
