; Penumbra SwiftUI overlay — layered on upstream tree-sitter-swift highlights.
; Property wrappers and common SwiftUI view types get distinct captures for theme coloring.

; Common property-wrapper type names inside attributes
(modifiers
  (attribute
    (user_type
      (type_identifier) @attribute
      (#match? @attribute "^(State|Binding|Environment|EnvironmentObject|FetchRequest|FocusState|AppStorage|SceneStorage|ObservedObject|StateObject|Published|Observable|ViewBuilder|MainActor|Preview|UIApplicationDelegateAdaptor|NSApplicationDelegateAdaptor|WKApplicationDelegateAdaptor|AccessibilityFocusState|GestureState|ScaledMetric|Namespace|Bindable|Model|Query)$"))))

; SwiftUI view types in call position — reads as built-in types rather than plain calls
(call_expression
  (simple_identifier) @type.builtin
  (#match? @type.builtin "^(Text|Image|Button|Toggle|Label|Link|VStack|HStack|ZStack|LazyVStack|LazyHStack|LazyVGrid|LazyHGrid|Grid|List|Form|Section|NavigationStack|NavigationSplitView|NavigationLink|ScrollView|TabView|Spacer|Divider|ProgressView|Slider|Picker|DatePicker|ColorPicker|Menu|ToolbarItem|Group|AnyView|EmptyView|ContentUnavailableView|Gauge|Chart|Canvas|Map|Table|OutlineGroup|DisclosureGroup|ControlGroup|GeometryReader|ViewThatFits|GridRow|NavigationView|TextField|SecureField|TextEditor|Stepper|Color|Circle|Rectangle|RoundedRectangle|Capsule|Ellipse|Path|AsyncImage|TimelineView|ShareLink|HelpLink|SettingsLink|RenameButton|PasteButton|FileImporter|FileExporter|WindowGroup|Settings|Commands|App|Document|Window|Scene)$"))
