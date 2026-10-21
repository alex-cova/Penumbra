//! target: self:d
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalSwitchPattern {
    void m(Object o) { switch (o) { case Dog d -> /*|*/d.speak(); default -> {} } }
}
