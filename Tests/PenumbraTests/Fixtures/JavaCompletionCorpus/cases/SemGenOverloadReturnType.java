//! contains: toUpperCase
//! excludes: intValue
package com.acme.cases;
class SemGenOverloadReturnType {
    static String pick(String s) { return s; }
    static Integer pick(Integer i) { return i; }
    void test() {
        pick("a").toUp/*|*/
    }
}
