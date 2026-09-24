//! excludes: continue
package com.acme.cases;

import com.acme.model.*;

class KeywordNoContinueInSwitch {
    void test(User user) {
        switch (user.getAge()) {
            case 1:
                con/*|*/
        }
    }
}
