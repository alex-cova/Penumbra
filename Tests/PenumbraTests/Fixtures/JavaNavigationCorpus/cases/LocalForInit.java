//! target: self:i
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalForInit {
    int m() { for (int i = 0; i < 3; i++) { return /*|*/i; } return 0; }
}
