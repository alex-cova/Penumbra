//! receiver: java.lang.String
//! contains: length, isEmpty
package com.acme.cases;

import java.util.*;

record Box(String value) {}
class AttrPatternSwitchRecord {
    void test(Object o) {
        switch (o) {
            case Box(String v) -> v./*|*/
        }
    }
}
