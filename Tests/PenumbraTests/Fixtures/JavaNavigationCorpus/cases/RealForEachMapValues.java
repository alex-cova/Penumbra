//! target: model/User.java:getRole
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealForEachMapValues {
    void m(Map<String, User> byId) { for (User u : byId.values()) { u./*|*/getRole(); } }
}
