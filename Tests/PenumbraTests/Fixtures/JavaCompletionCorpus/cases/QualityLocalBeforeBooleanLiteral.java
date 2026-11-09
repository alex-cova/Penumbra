//! top1: type
package com.acme.cases;

class QualityLocalBeforeBooleanLiteral {
    boolean test(Class<?> type) {
        if (t/*|*/ == int.class) {
            return true;
        }
        return false;
    }
}
