//! receiver: array
//! receiverType: byte[]
//! oracle-completion: zzProbe()
//! contains: length, clone
package com.acme.cases;

import com.acme.model.*;
import java.time.format.DateTimeParseException;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GapAnonymousClassFieldByName {
    Runnable r = new Runnable() { private static final byte[] KEY = new byte[0]; public void run() { int n = KEY./*|*/; } };
    void test() {
        
    }
}
