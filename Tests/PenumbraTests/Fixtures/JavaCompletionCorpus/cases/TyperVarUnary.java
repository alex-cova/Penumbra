//! receiver: java.lang.Integer
//! contains: intValue
package com.acme.cases;

class TyperVarUnary {
    void test(int count) {
        var negative = -count;
        Integer boxed = negative;
        boxed./*|*/
    }
}
