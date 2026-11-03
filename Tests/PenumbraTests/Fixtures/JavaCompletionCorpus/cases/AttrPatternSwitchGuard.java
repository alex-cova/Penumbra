//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

import java.util.*;

class AttrPatternSwitchGuard {
    void test(Object o) {
        switch (o) {
            case Integer i when i > 3 -> i./*|*/
        }
    }
}
