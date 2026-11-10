//! receiverType: java.lang.Class<? extends java.lang.String[]>
//! contains: getComponentType, isArray, cast
//! oracle: javac captures the wildcard (Class<capture#1 of ? extends String[]>); the engine keeps ? extends String[], whose members are the capture's
package com.acme.cases;

import com.acme.model.*;
import java.util.*;

class GapArrayGetClass {
    void test(String[] names) {
        names.getClass()./*|*/
    }
}
