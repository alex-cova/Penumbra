//! contains: toUpperCase
package com.acme.cases;
class SemGenCastReceiver {
    void test(Object o) {
        ((String) o).toUp/*|*/
    }
}
