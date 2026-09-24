//! excludes: of, copyOf
//! contains: size, get, stream
package com.acme.cases;

import java.util.*;

class MemberNoStaticInterfaceViaInstance {
    void test(List<String> names, ArrayList<String> list) {
        names./*|*/
    }
}
