//! contains: name
package com.acme.cases;
class SemGenRecordAccessor {
    record Person(String name, int age) {}
    void test(Person p) {
        p.na/*|*/
    }
}
