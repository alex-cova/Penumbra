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

class RealOptionalOrElseThrow {
    String m(UserDirectory dir) { return dir.findById("1").orElseThrow()./*|*/getName(); }
}
