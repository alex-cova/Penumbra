//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

class AttrPatternSwitchType {
    void test(Object o) {
        switch (o) {
            case String s -> s./*|*/
        }
    }
}
