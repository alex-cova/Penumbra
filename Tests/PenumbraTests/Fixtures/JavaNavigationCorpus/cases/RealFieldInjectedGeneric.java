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

class RealFieldInjectedGeneric {
    private final Repository<User, String> repo = null;
    String m() { return repo.findAll().get(0)./*|*/getName(); }
}
