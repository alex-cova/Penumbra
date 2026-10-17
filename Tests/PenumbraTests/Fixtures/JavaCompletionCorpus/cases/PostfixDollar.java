//! applies: par
//! yields: ("a$b")
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;

class PostfixDollar {
    void test() {
        "a$b".par/*|*/
    }
}
