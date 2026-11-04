//! receiver: java.lang.Number
//! contains: intValue
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Cap17ClassTypeVarBound<N extends Number> {
    List<N> items;
    void f() {
        items.get(0)./*|*/
    }
}
