//! target: model/Level.java:label
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealEnumInstanceMethod {
    String m(Level level) { return level./*|*/label(); }
}
