//! receiver: array
//! receiverType: int[]
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import java.util.*;
import java.util.stream.*;

class LamOverloadStreamOfPrimitiveArray {
    void test(int[] ints) {
        Stream.of(ints).findFirst().get()./*|*/
    }
}
