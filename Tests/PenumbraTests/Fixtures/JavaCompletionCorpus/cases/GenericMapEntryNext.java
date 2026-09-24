//! receiver: java.util.Map.Entry
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class GenericMapEntryNext {
    void test(Map<String, User> byId) {
        byId.entrySet().iterator().next()./*|*/
    }
}
