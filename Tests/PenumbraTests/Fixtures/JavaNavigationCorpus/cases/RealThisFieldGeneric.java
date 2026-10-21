//! target: generic/Repository.java:findById
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealThisFieldGeneric {
    private final Repository<User, String> repo = null;
    void m() { this.repo./*|*/findById("1"); }
}
