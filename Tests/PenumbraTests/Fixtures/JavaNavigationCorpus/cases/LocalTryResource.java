//! target: self:res
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalTryResource {
    void m() throws Exception { try (java.io.StringReader res = new java.io.StringReader("")) { /*|*/res.read(); } }
}
