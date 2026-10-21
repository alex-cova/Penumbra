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

class RealVarFromGenericCall {
    String m(Repository<User, String> repo) { var users = repo.findAll(); return users.get(0)./*|*/getName(); }
}
