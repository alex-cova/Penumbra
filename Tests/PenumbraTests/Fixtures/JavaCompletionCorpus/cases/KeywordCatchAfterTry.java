//! contains: catch
package com.acme.cases;

import com.acme.model.*;

class KeywordCatchAfterTry {
    void test(User user) {
        try {
            user.getName();
        } ca/*|*/
    }
}
