//! target: model/Point.java:x
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodRecordAccessor {
    int m(Point p) { return p./*|*/x(); }
}
