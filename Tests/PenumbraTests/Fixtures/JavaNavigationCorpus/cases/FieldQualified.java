//! target: model/Ball.java:size
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldQualified {
    int m(Ball b) { return b./*|*/size; }
}
