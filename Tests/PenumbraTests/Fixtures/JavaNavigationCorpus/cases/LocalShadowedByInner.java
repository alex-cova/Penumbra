//! target: self:value
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalShadowedByInner {
    int value;
    int m() { int value = 2; return /*|*/value; }
}
