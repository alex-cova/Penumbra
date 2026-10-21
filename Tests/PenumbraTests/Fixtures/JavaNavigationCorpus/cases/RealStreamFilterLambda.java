//! target: model/Role.java:isAdmin
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealStreamFilterLambda {
    List<User> m(List<User> users) { return users.stream().filter(u -> u.getRole()./*|*/isAdmin()).toList(); }
}
