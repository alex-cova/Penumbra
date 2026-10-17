//! mode: dotDot
//! contains: Extract Method…,Surround With…
//! command: Extract Method…
//! action: extractMethod
//! selects: for (int i = 0; i < 3; i++) { tick(); }
package com.acme.cases;

class CommandDotDotBlock {
    void test() {
        for (int i = 0; i < 3; i++) { tick(); }../*|*/
    }

    void tick() {}
}
