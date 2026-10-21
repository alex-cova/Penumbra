//! package-dirs: com/acme/model
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class JavadocLinkQualifiedPackage {
    /** See {@link com.acme./*|*/model.Dog}. */
    void m() {}
}
