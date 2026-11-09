//! contains: toUpperCase
package com.acme.cases;
class SemGenTernaryReceiver {
    void test(boolean f, String a, String b) {
        (f ? a : b).toUp/*|*/
    }
}
