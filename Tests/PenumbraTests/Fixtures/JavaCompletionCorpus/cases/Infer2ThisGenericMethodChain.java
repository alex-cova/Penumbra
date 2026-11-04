//! receiver: java.lang.String
//! contains: length
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.*;
import java.util.stream.*;

class Infer2ThisGenericMethodChain {
    static class Node<T> { Node<T> next; T val; Node<T> next() { return next; } }
    void test() throws Exception {
        Node<String> n = null; n.next().next().val./*|*/
    }
}
