import Foundation
import JavaIntelligence

/// What a class is, as far as Spring's component model goes.
public enum SpringStereotype: String, Hashable, Sendable {
    case component, service, repository, controller, restController, configuration
    case controllerAdvice, springBootApplication
}

/// Spring's own annotations and the stereotypes they imply through meta-annotation. Annotations in
/// dependency JARs carry no annotation data in `JavaClassStub`, so the framework's well-known ones
/// are listed here; the project's own composed annotations are resolved from source.
enum SpringAnnotationRegistry {
    static let stereotypes: [String: Set<SpringStereotype>] = {
        let c = "org.springframework.stereotype."
        let web = "org.springframework.web.bind.annotation."
        let ctx = "org.springframework.context.annotation."
        return [
            c + "Component": [.component],
            c + "Service": [.service, .component],
            c + "Repository": [.repository, .component],
            c + "Controller": [.controller, .component],
            web + "RestController": [.restController, .controller, .component],
            web + "ControllerAdvice": [.controllerAdvice, .component],
            web + "RestControllerAdvice": [.controllerAdvice, .component],
            ctx + "Configuration": [.configuration, .component],
            "org.springframework.boot.SpringBootConfiguration": [.configuration, .component],
            "org.springframework.boot.autoconfigure.SpringBootApplication": [.springBootApplication, .configuration, .component],
            "jakarta.inject.Named": [.component],
            "javax.inject.Named": [.component],
            "jakarta.annotation.ManagedBean": [.component],
            "javax.annotation.ManagedBean": [.component],
        ]
    }()

    static let beanMethod = "org.springframework.context.annotation.Bean"
    static let autowired = "org.springframework.beans.factory.annotation.Autowired"
    static let qualifier = "org.springframework.beans.factory.annotation.Qualifier"
    static let primary = "org.springframework.context.annotation.Primary"
    static let fallback = "org.springframework.context.annotation.Fallback"
    static let lazy = "org.springframework.context.annotation.Lazy"
    static let scope = "org.springframework.context.annotation.Scope"
    static let profile = "org.springframework.context.annotation.Profile"
    static let conditional = "org.springframework.context.annotation.Conditional"
    static let componentScan = "org.springframework.context.annotation.ComponentScan"
    static let importAnnotation = "org.springframework.context.annotation.Import"
    static let importResource = "org.springframework.context.annotation.ImportResource"
    static let value = "org.springframework.beans.factory.annotation.Value"
    static let configurationProperties = "org.springframework.boot.context.properties.ConfigurationProperties"
    static let injectNames: Set<String> = ["jakarta.inject.Inject", "javax.inject.Inject"]
    static let resourceNames: Set<String> = ["jakarta.annotation.Resource", "javax.annotation.Resource"]
    static let namedNames: Set<String> = ["jakarta.inject.Named", "javax.inject.Named"]
    static let conditionalPrefix = "org.springframework.boot.autoconfigure.condition.Conditional"

    static let deferredWrappers: Set<String> = [
        "java.util.Optional", "org.springframework.beans.factory.ObjectProvider",
        "org.springframework.beans.factory.ObjectFactory", "jakarta.inject.Provider", "javax.inject.Provider",
    ]
    static let collectionTypes: Set<String> = ["java.util.List", "java.util.Set", "java.util.Collection", "java.util.SortedSet"]
    static let javaUtil: Set<String> = ["List", "Set", "Map", "Optional", "Collection", "SortedSet"]
    static let javaLang: Set<String> = [
        "String", "Object", "Integer", "Long", "Boolean", "Double", "Float", "Short", "Byte", "Character",
        "Number", "Runnable", "Iterable", "Comparable", "CharSequence", "Exception", "RuntimeException",
    ]
}
