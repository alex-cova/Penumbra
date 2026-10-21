package com.acme.model;

public @interface Marker {
    String value() default "";

    int timeout() default 0;
}
