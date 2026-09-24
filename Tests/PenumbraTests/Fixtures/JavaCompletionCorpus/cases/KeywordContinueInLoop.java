//! contains: continue
package com.acme.cases;

import com.acme.model.*;

class KeywordContinueInLoop {
    void test(User user) {
        while (user.isActive()) {
            con/*|*/
        }
    }
}
