//! target: model/Marker.java:value
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class AnnotationSingleValue {
    @Marker(/*|*/value = "x")
    void m() {}
}
