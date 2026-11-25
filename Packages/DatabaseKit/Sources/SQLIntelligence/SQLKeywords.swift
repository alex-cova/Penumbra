import Foundation

public struct SQLFunction: Equatable, Sendable {
    public var name: String
    /// `count(expression)`, shown in the completion detail and in signature help.
    public var signature: String
    public var summary: String
}

/// The dialect's words: what can start a statement, what can follow a table, which functions and
/// types exist. Static data, one place, tested for shape.
public enum SQLKeywords {
    public static func statementStarters(_ dialect: SQLDialect) -> [String] {
        var words = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "EXPLAIN", "BEGIN", "COMMIT", "ROLLBACK", "VALUES"]
        switch dialect {
        case .postgres: words += ["TRUNCATE", "COPY", "ANALYZE", "VACUUM", "SET", "SHOW", "GRANT", "REVOKE", "DO", "TABLE", "MERGE", "SAVEPOINT", "RELEASE"]
        case .mysql: words += ["REPLACE", "TRUNCATE", "SHOW", "DESCRIBE", "USE", "SET", "GRANT", "REVOKE", "CALL", "ANALYZE", "OPTIMIZE", "START", "SAVEPOINT", "RELEASE", "LOCK", "UNLOCK"]
        case .sqlite: words += ["REPLACE", "PRAGMA", "VACUUM", "ANALYZE", "ATTACH", "DETACH", "REINDEX", "SAVEPOINT", "RELEASE"]
        }
        return words.sorted()
    }

    /// After a complete table reference in FROM.
    public static func afterSource(_ dialect: SQLDialect) -> [String] {
        var words = ["WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "UNION", "INTERSECT", "EXCEPT", "JOIN", "INNER JOIN", "LEFT JOIN", "LEFT OUTER JOIN", "CROSS JOIN", "NATURAL JOIN"]
        switch dialect {
        case .postgres: words += ["RIGHT JOIN", "FULL JOIN", "OFFSET", "FETCH", "WINDOW", "FOR UPDATE", "TABLESAMPLE", "RETURNING"]
        case .mysql: words += ["RIGHT JOIN", "STRAIGHT_JOIN", "OFFSET", "WINDOW", "FOR UPDATE", "PARTITION"]
        case .sqlite: words += ["OFFSET", "WINDOW", "INDEXED BY", "NOT INDEXED"]
        }
        return words
    }

    /// In a condition, after an operand.
    public static let afterOperand = ["AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "IS NULL", "IS NOT NULL", "GROUP BY", "ORDER BY", "LIMIT", "HAVING", "UNION", "EXCEPT", "INTERSECT"]

    public static let expressionKeywords = ["CASE", "NOT", "NULL", "TRUE", "FALSE", "EXISTS", "DISTINCT", "ALL", "ANY", "CAST", "INTERVAL"]

    public static func types(_ dialect: SQLDialect) -> [String] {
        switch dialect {
        case .postgres: ["bigint", "bigserial", "boolean", "bytea", "char", "date", "double precision", "inet", "integer", "interval", "json", "jsonb", "numeric", "real", "serial", "smallint", "text", "time", "timestamp", "timestamptz", "uuid", "varchar"]
        case .mysql: ["bigint", "binary", "blob", "char", "date", "datetime", "decimal", "double", "enum", "float", "int", "json", "longtext", "mediumint", "set", "smallint", "text", "time", "timestamp", "tinyint", "varchar", "year"]
        case .sqlite: ["blob", "integer", "numeric", "real", "text", "boolean", "date", "datetime", "varchar", "decimal"]
        }
    }

    /// Cross-dialect functions plus each dialect's own.
    public static func functions(_ dialect: SQLDialect) -> [SQLFunction] {
        var all = common
        switch dialect {
        case .postgres: all += postgres
        case .mysql: all += mysql
        case .sqlite: all += sqlite
        }
        return all.sorted { $0.name < $1.name }
    }

    public static func function(named name: String, _ dialect: SQLDialect) -> SQLFunction? {
        functions(dialect).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func f(_ name: String, _ signature: String, _ summary: String) -> SQLFunction {
        SQLFunction(name: name, signature: signature, summary: summary)
    }

    private static let common: [SQLFunction] = [
        f("abs", "abs(x)", "Absolute value."), f("avg", "avg(expression)", "Average of the non-null values."),
        f("coalesce", "coalesce(value, …)", "The first argument that is not NULL."), f("count", "count(expression | *)", "Number of rows, or of non-null values."),
        f("length", "length(string)", "Length of a string."), f("lower", "lower(string)", "Lower-case copy of a string."),
        f("max", "max(expression)", "Largest value."), f("min", "min(expression)", "Smallest value."),
        f("nullif", "nullif(a, b)", "NULL if a equals b, otherwise a."), f("replace", "replace(string, from, to)", "Replace every occurrence of a substring."),
        f("round", "round(x [, digits])", "Round to a number of decimal places."), f("sum", "sum(expression)", "Sum of the non-null values."),
        f("trim", "trim(string)", "Remove leading and trailing spaces."), f("upper", "upper(string)", "Upper-case copy of a string."),
    ]
    private static let postgres: [SQLFunction] = [
        f("array_agg", "array_agg(expression)", "Collect values into an array."), f("concat", "concat(value, …)", "Join values as text; NULLs are ignored."),
        f("current_date", "current_date", "Today's date."), f("date_trunc", "date_trunc(field, source)", "Truncate a timestamp to a precision."),
        f("generate_series", "generate_series(start, stop [, step])", "A set of numbers or timestamps."), f("jsonb_agg", "jsonb_agg(expression)", "Aggregate values into a JSON array."),
        f("jsonb_build_object", "jsonb_build_object(key, value, …)", "Build a JSON object."), f("now", "now()", "Start time of the transaction."),
        f("string_agg", "string_agg(expression, delimiter)", "Join values with a delimiter."), f("substring", "substring(string [from start] [for length])", "Part of a string."),
        f("to_char", "to_char(value, format)", "Format a value as text."), f("to_timestamp", "to_timestamp(text, format)", "Parse text to a timestamp."),
    ]
    private static let mysql: [SQLFunction] = [
        f("concat", "concat(string, …)", "Join strings; NULL if any is NULL."), f("concat_ws", "concat_ws(separator, string, …)", "Join strings with a separator."),
        f("curdate", "curdate()", "Today's date."), f("date_format", "date_format(date, format)", "Format a date as text."),
        f("group_concat", "group_concat(expression [SEPARATOR str])", "Concatenate group values."), f("if", "if(condition, then, else)", "Choose by a condition."),
        f("ifnull", "ifnull(a, b)", "b when a is NULL."), f("json_extract", "json_extract(document, path)", "A value from a JSON document."),
        f("now", "now()", "Current date and time."), f("substring", "substring(string, start [, length])", "Part of a string."),
    ]
    private static let sqlite: [SQLFunction] = [
        f("date", "date(time, modifier, …)", "Date as YYYY-MM-DD."), f("datetime", "datetime(time, modifier, …)", "Date and time as text."),
        f("group_concat", "group_concat(expression [, separator])", "Concatenate group values."), f("ifnull", "ifnull(a, b)", "b when a is NULL."),
        f("iif", "iif(condition, then, else)", "Choose by a condition."), f("json_extract", "json_extract(document, path, …)", "A value from a JSON document."),
        f("julianday", "julianday(time, modifier, …)", "Julian day number."), f("printf", "printf(format, …)", "Format values as text."),
        f("random", "random()", "A random 64-bit integer."), f("strftime", "strftime(format, time, modifier, …)", "Format a time."),
        f("substr", "substr(string, start [, length])", "Part of a string."), f("typeof", "typeof(expression)", "Storage class of a value."),
    ]
}
