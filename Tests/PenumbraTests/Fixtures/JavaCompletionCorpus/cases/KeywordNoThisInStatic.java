//! excludes: this, super
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class KeywordNoThisInStatic {
    static void test() {
        th/*|*/
    }
}
