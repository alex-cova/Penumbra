//! applies: for
//! yields: for (Map.Entry<String, User> entry : entries) {
package com.acme.cases;

import com.acme.model.*;
import java.util.*;

class PostfixForEntries {
    void test(Map<String, User> byId) {
        Set<Map.Entry<String, User>> entries = byId.entrySet();
        entries.for/*|*/
    }
}
