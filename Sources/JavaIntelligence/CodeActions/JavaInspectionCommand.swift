/// Ids of the code-action commands inspection findings carry; the host performs them (they change
/// its inspection profile, which the engine does not own). The argument is the rule code.
public enum JavaInspectionCommand {
    /// Switch the rule off.
    public static let disable = "java.inspection.disable"
    /// Set the rule to "No highlighting (fix available)".
    public static let quiet = "java.inspection.quiet"
    /// Open the inspection settings on the rule.
    public static let configure = "java.inspection.configure"
}
