//! target: model/User.java:getName
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import com.acme.service.*;
import java.util.function.*;

class RealInheritedGenericResult {
    String m(UserDirectory dir, User u) { return dir.save(u)./*|*/getName(); }
}
