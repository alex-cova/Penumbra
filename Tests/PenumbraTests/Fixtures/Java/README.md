# Java class-file fixtures

Small, hand-picked `.class` files (and one `.jar`) used by `ClassFileReaderTests` and friends,
covering generics, inner/nested classes, records, enums, varargs, deprecated members and
`MethodParameters`. Regenerate with:

```
javac --release 17 -parameters -g:none Fixture*.java
```

`-parameters` keeps the `MethodParameters` attribute (needed for named-parameter tests);
`-g:none` keeps the files small since debug info isn't read by `ClassFileReader`.
