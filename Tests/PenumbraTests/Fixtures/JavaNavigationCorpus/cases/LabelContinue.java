//! target: self:outer
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LabelContinue {
    void m() { outer: for (;;) { for (;;) { continue /*|*/outer; } } }
}
