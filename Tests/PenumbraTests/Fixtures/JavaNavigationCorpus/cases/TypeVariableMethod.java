//! target: self:R
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeVariableMethod {
    <R> /*|*/R pick(R first) { return first; }
}
