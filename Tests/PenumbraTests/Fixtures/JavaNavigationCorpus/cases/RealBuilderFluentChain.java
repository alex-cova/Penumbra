//! target: model/Account.java:balance
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealBuilderFluentChain {
    Account m() { return Account.builder().owner("x")./*|*/balance(3).build(); }
}
