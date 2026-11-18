import Foundation
import JavaIntelligence

/// How sure the static model is about a fact. Static analysis never claims runtime certainty:
/// even `.certain` means "every input the analysis can see agrees", not "confirmed running".
public enum SpringCertainty: Hashable, Sendable {
    /// Registered unconditionally as far as the sources show.
    case certain
    /// Registered only if a condition holds that static analysis cannot (fully) decide.
    case conditional(reasons: [String])
    /// Excluded under the active analysis profiles.
    case inactive(reasons: [String])

    public var isConditional: Bool { if case .conditional = self { return true } else { return false } }
    public var isInactive: Bool { if case .inactive = self { return true } else { return false } }
}

public struct SpringSourceLocation: Hashable, Sendable {
    public let url: URL
    /// UTF-8 byte range of the declaring name.
    public let byteRange: Range<Int>

    public init(url: URL, byteRange: Range<Int>) {
        self.url = url
        self.byteRange = byteRange
    }
}

/// A type as the Spring layer sees it: a qualified name when resolution succeeded, otherwise the
/// simple name as written (`isResolved == false`), plus type arguments.
public struct SpringType: Hashable, Sendable {
    public let name: String
    public let isResolved: Bool
    public let arguments: [SpringType]
    public var simpleName: String { name.split(separator: ".").last.map(String.init) ?? name }
}

public struct SpringBeanID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }
}

public enum SpringBeanOrigin: Hashable, Sendable {
    /// A class carrying a stereotype (directly or through a composed annotation).
    case stereotype(annotation: String)
    /// A `@Bean` method of `configuration`.
    case factoryMethod(configuration: String, method: String)
}

public struct SpringBean: Hashable, Sendable {
    public let id: SpringBeanID
    public let name: String
    public let aliases: [String]
    public let type: SpringType
    public let qualifiers: [String]
    public let isPrimary: Bool
    public let isFallback: Bool
    public let scope: String
    public let origin: SpringBeanOrigin
    public let certainty: SpringCertainty
    public let location: SpringSourceLocation
    public let isLazy: Bool
    /// Start of the declaring class or `@Bean` method, where an annotation such as `@Primary` is inserted.
    public let declarationStart: Int
    /// What the class is (`@Service`, `@RestController`, a `@Configuration`…); empty for a `@Bean` method.
    public let stereotypes: Set<SpringStereotype>
}

/// A concrete project class that would satisfy an injection point but is not registered as a bean.
public struct SpringUnregisteredType: Hashable, Sendable {
    public let typeName: String
    public let location: SpringSourceLocation
    public let declarationStart: Int
}

public enum SpringInjectionKind: Hashable, Sendable { case constructor, field, method, factoryParameter }

public enum SpringInjectionShape: Hashable, Sendable {
    case single
    /// `List<T>`, `Set<T>`, `Collection<T>`, `T[]`, `Map<String, T>`: zero matches are allowed.
    case collection
}

public struct SpringInjectionPoint: Hashable, Sendable {
    /// An injection point is identified by what declares it and where its name is. The struct is a dictionary key in every
    /// model (resolutions, candidates, consumers), and hashing all of it (type, file URL, ranges) was most of the cost of
    /// building the tool window's data; the identity below is cheap and no two points of one file can share it.
    public static func == (lhs: SpringInjectionPoint, rhs: SpringInjectionPoint) -> Bool {
        lhs.nameRange == rhs.nameRange && lhs.owner == rhs.owner && lhs.name == rhs.name && lhs.kind == rhs.kind
            && lhs.location.url == rhs.location.url
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(owner)
        hasher.combine(nameRange.lowerBound)
    }

    public let owner: SpringBeanID
    public let kind: SpringInjectionKind
    public let name: String
    public let requiredType: SpringType
    public let shape: SpringInjectionShape
    public let qualifier: String?
    public let isRequired: Bool
    /// `Optional`, `ObjectProvider`, `Provider` or `@Lazy`: resolved at use, not at creation.
    public let isDeferred: Bool
    /// The whole parameter or field name (what diagnostics underline).
    public let location: SpringSourceLocation
    /// Just the declared name, for navigation hit-testing.
    public let nameRange: Range<Int>
    /// The `@Qualifier`/`@Named`/`@Resource` annotation, when the point has one.
    public let qualifierRange: Range<Int>?
    /// Where a new annotation for this point is inserted: the start of its parameter or field declaration.
    public let annotationInsertOffset: Int
}

public enum SpringResolution: Hashable, Sendable {
    case resolved(SpringBeanID)
    case collection([SpringBeanID])
    /// Several candidates and no qualifier, `@Primary` or name match picks one.
    case ambiguous([SpringBeanID])
    /// No candidate, and every implementation of the type is in the project's sources.
    case missing
    /// No certain candidate, but conditional ones exist, or registration this model cannot see
    /// (library type, `@Import`, XML) may supply one.
    case uncertain(candidates: [SpringBeanID], reason: String)
    /// A qualifier named something no bean answers to.
    case unknownQualifier(String)
}

public enum SpringDiagnosticSeverity: Hashable, Sendable { case error, warning, info }

public struct SpringDiagnostic: Hashable, Sendable {
    public let severity: SpringDiagnosticSeverity
    public let code: String
    public let message: String
    public let location: SpringSourceLocation
    /// Related candidates, for the "navigate to candidates" quick fix.
    public let related: [SpringBeanID]
    /// A replacement the quick fix can offer (the path variable a parameter probably meant).
    public var suggestion: String? = nil
}

public struct SpringDependencyCycle: Hashable, Sendable {
    public enum Strength: Hashable, Sendable {
        /// Every edge is constructor injection of non-deferred singletons: Spring fails at startup.
        case proven
        /// Includes field/setter edges: Spring Framework tolerates it, Spring Boot 2.6+ rejects it by default.
        case dependsOnConfiguration
    }
    public let beans: [SpringBeanID]
    public let strength: Strength
}

/// A relationship between configuration classes that shapes which beans a context has.
public struct SpringConfigurationLink: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `@ComponentScan` / `@SpringBootApplication`: the package scanned.
        case scan(package: String)
        /// `@Import(Target.class)`; `resolved` is false when the target is not in the project's sources (a library).
        case importClass(target: String, resolved: Bool)
        /// `@ImportResource`: XML or Groovy bean definitions this model does not read.
        case importResource(locations: [String])
    }
    public let from: String
    public let kind: Kind
    public let location: SpringSourceLocation
}
