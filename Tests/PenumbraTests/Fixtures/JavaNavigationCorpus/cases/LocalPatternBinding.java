//! target: self:d
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalPatternBinding {
    void m(Object o) { if (o instanceof Dog d) { /*|*/d.speak(); } }
}
