# Provider contract

`InlayHintProviding` receives an immutable document and a range in UTF-16 document coordinates. The editor requests a bounded overscan range and validates results against the current content generation before publishing. Providers must resolve against the request snapshot, cooperate with task cancellation, and suppress ambiguous results. Results carry display data and anchors. Java reuses the read-only parse memo used by navigation. Language service routing owns provider precedence.
