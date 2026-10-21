//! target: self:total
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalVariable {
    int m() { int total = 1; return /*|*/total; }
}
