//! target: service/UserDirectory.java:save
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

class RealInheritedGenericSave {
    User m(UserDirectory dir, User u) { return dir./*|*/save(u); }
}
