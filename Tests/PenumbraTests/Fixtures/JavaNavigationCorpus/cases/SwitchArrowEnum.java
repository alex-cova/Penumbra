//! target: model/Role.java:USER
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class SwitchArrowEnum {
    int m(Role r) { return switch (r) { case ADMIN -> 1; case /*|*/USER -> 2; }; }
}
