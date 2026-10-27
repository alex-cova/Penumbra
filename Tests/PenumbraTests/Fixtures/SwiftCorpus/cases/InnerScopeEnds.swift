func f() {
    do { let inner = 1; _ = inner }
    /*|*/
}
//! excludes: inner
