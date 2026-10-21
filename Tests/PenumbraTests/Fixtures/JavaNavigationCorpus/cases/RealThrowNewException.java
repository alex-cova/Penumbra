//! target: exception/BadRequestException.java:BadRequestException
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealThrowNewException {
    void m() { throw new /*|*/BadRequestException("k", "m"); }
}
