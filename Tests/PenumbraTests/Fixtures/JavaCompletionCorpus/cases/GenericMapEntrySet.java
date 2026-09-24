//! receiver: java.util.Set
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class GenericMapEntrySet {
    void test(Map<String, User> byId) {
        byId.entrySet()./*|*/
    }
}
