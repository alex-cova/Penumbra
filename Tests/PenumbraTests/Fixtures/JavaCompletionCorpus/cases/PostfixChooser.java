//! chooser: var = b | a + b
//! applies: var
//! yields: int i = b;
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixChooser {
    void test() {
        int a = 1;
        int b = 2;
        a + b.var/*|*/
    }
}
