//! receiverType: java.lang.Throwable
//! contains: getMessage, getCause, printStackTrace
//! excludes: getParsedString, getErrorIndex
//! oracle: NotIndexed is on no classpath. javac reports it and types e as DateTimeParseException, the lub of the alternatives it could resolve (error recovery); JLS 14.20 proves only Throwable
package com.acme.cases;

import com.acme.missing.NotIndexed;
import java.time.format.DateTimeParseException;

class GapMultiCatchMissingAlternative {
    void run() { }
    void test() {
        try { run(); } catch (DateTimeParseException | NotIndexed e) { e./*|*/ }
    }
}
