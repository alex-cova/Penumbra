//! expected: java.util.Collection<? extends com.acme.model.Named>
//! top1: users
package com.acme.cases;

import com.acme.model.*;
import java.util.*;

class ExpectedWildcardExtends {
    void test(List<Dog> dogs, List<User> users) {
        Collection<? extends Named> named = /*|*/
    }
}
