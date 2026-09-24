//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

record ScopeRecordComponent(String title, int pages) {
    int test() {
        return title./*|*/
    }
}
