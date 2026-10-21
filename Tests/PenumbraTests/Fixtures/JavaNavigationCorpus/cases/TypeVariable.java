//! target: self:T
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class TypeVariable {
    static class Holder<T> { /*|*/T value; }
}
