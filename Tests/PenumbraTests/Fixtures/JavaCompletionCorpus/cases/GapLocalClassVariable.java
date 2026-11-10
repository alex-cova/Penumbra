//! contains: list
package com.acme.cases;

import java.util.*;
import java.util.function.*;

class GapLocalClassVariable {
    void test() {
        class Acc { List<String> list; }
        Acc a = new Acc();
        a./*|*/;
    }
}
