//! site: annotation
//! top1: Override
//! contains: Override
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class SiteAnnotation extends Animal {
    @Overr/*|*/
    public String sound() { return ""; }
}
