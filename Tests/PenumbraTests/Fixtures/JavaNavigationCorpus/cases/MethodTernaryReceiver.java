//! target: model/Dog.java:speak
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class MethodTernaryReceiver {
    String m(boolean b, Dog x, Dog y) { return (b ? x : y)./*|*/speak(); }
}
