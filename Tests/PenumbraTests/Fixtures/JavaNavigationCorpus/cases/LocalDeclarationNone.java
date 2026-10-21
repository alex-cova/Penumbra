//! none: true
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalDeclarationNone {
    int m() { int /*|*/value = 1; return value; }
}
