//! target: model/User.java:of
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealStaticCallThroughOuter {
    User m() { return User./*|*/of("x"); }
}
