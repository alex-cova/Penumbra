//! receiver: array
//! receiverType: byte[]
//! contains: length, clone
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapCStyleArrayParameter {
    void test(byte b[]) {
        b./*|*/
    }
}
