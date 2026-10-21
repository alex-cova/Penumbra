//! target: model/Point.java:dist
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodOnRecord {
    double m(Point p) { return p./*|*/dist(); }
}
