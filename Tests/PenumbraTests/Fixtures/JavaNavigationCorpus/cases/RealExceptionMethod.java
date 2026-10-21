//! target: exception/BadRequestException.java:getErrorCode
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealExceptionMethod {
    int m(BadRequestException e) { return e./*|*/getErrorCode(); }
}
