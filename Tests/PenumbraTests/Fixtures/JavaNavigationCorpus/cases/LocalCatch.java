//! target: self:ex
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalCatch {
    void m() { try { } catch (RuntimeException ex) { /*|*/ex.printStackTrace(); } }
}
