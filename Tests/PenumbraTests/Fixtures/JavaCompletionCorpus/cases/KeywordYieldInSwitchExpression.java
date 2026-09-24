//! contains: yield
package com.acme.cases;

import com.acme.model.*;

class KeywordYieldInSwitchExpression {
    void test(User user) {
        int size = switch (user.getAge()) {
            case 1 -> 1;
            default -> {
                yi/*|*/
            }
        };
    }
}
