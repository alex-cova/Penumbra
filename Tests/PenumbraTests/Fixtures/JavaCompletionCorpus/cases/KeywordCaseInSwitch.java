//! contains: case
package com.acme.cases;

import com.acme.model.*;

class KeywordCaseInSwitch {
    void test(User user) {
        switch (user.getAge()) {
            case 1:
                break;
            ca/*|*/
        }
    }
}
