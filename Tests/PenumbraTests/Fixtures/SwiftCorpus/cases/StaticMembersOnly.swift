struct Config {
    static let shared = Config()
    static func make() -> Config { Config() }
    var value = 0
}
let c = Config./*|*/
//! contains: shared, make
//! excludes: value
