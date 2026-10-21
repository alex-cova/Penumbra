//! target: self:x
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalRecordPattern {
    int m(Object o) { if (o instanceof Point(int x, int y)) { return /*|*/x; } return 0; }
}
