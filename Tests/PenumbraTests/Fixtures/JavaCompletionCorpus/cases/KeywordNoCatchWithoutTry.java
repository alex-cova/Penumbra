//! excludes: catch
package com.acme.cases;

import com.acme.model.*;

class KeywordNoCatchWithoutTry {
    void test(User user) {
        user.getName();
        ca/*|*/
    }
}
