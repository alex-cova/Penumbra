//! target: model/Marker.java:timeout
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class AnnotationElement {
    @Marker(/*|*/timeout = 5)
    void m() {}
}
