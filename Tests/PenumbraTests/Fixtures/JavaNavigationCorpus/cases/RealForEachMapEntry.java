//! target: model/User.java:getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealForEachMapEntry {
    void m(Map<String, User> byId) { for (Map.Entry<String, User> e : byId.entrySet()) { e.getValue()./*|*/getName(); } }
}
