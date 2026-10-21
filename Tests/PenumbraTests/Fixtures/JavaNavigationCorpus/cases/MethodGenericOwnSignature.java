//! target: self:pick
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodGenericOwnSignature {
    <R> R pick(R first) { return first; }
    String m() { return /*|*/pick("a"); }
}
