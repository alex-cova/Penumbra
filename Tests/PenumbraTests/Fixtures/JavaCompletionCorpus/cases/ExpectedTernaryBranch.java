//! expected: java.lang.String
//! top1: label
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ExpectedTernaryBranch {
    String test(boolean flag, String label, int count) {
        return flag ? label : /*|*/
    }
}
