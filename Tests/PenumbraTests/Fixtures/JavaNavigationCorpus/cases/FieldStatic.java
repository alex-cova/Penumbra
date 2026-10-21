//! target: model/Animal.java:LEGS
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class FieldStatic {
    int m() { return Animal./*|*/LEGS; }
}
