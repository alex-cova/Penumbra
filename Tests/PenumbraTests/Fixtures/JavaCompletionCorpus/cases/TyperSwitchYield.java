//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

class TyperSwitchYield {
    void test(int code) {
        (switch (code) { case 1: yield "one"; default: yield "many"; })./*|*/
    }
}
