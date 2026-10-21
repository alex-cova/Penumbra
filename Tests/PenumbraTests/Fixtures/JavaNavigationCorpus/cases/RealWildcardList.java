//! target: model/Animal.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealWildcardList {
    String m(List<? extends Animal> animals) { return animals.get(0)./*|*/speak(); }
}
