//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2EnumMapGet {
    enum Color { RED }
    void test() throws Exception {
        EnumMap<Color, String> m = new EnumMap<>(Color.class); m.get(Color.RED)./*|*/
    }
}
