//! contains: intValue
//! excludes: toUpperCase
package com.acme.cases;
class SemGenOverloadReturnTypeInteger {
    static String pick(String s) { return s; }
    static Integer pick(Integer i) { return i; }
    void test() {
        pick(1).int/*|*/
    }
}
