//! receiver: java.util.Iterator
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class GenericMapEntryIterator {
    void test(Map<String, User> byId) {
        byId.entrySet().iterator()./*|*/
    }
}
