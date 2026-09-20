import Foundation

/**
 * A simple 2D vector class which supports translation, scaling, normalization etc.
 */
package final class KVector: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    
    /** the default fuzzyness used when comparing two vectors fuzzily. */
    package static let defaultFuzziness: Double = 0.05
    
    /** x coordinate. */
    package var x: Double
    /** y coordinate. */
    package var y: Double

    /// Alias so KVector can be used to represent sizes (width maps to x).
    package var width: Double { get { x } set { x = newValue } }
    /// Alias so KVector can be used to represent sizes (height maps to y).
    package var height: Double { get { y } set { y = newValue } }
    
    /**
     * Create vector with default coordinates (0,0).
     */
    package init() {
        self.x = 0.0
        self.y = 0.0
    }
    
    /**
     * Constructs a new vector from given values.
     *
     * @param x x value
     * @param y y value
     */
    package init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// Labeled init for compatibility
    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    
    /**
     * Creates an exact copy of a given vector.
     *
     * @param other existing vector
     */
    package init(_ other: KVector) {
        self.x = other.x
        self.y = other.y
    }
    
    /**
     * Creates a new vector that points from the given start to the end vector.
     *
     * @param start start vector.
     * @param end end vector.
     */
    package init(_ start: KVector, _ end: KVector) {
        self.x = end.x - start.x
        self.y = end.y - start.y
    }
    
    /**
     * Creates a normalized vector for the passed angle in radians.
     *
     * @param angle angle in radians.
     */
    package init(_ angle: Double) {
        self.x = cos(angle)
        self.y = sin(angle)
    }
    
    /**
     * Returns an exact copy of this vector.
     *
     * @return identical vector
     */
    package func clone() -> KVector {
        return KVector(self)
    }
    
    package var description: String {
        return "(\(x),\(y))"
    }
    
    package var debugDescription: String {
        return self.description
    }
    
    package static func == (lhs: KVector, rhs: KVector) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
    
    /**
     * Calls {@link #equalsFuzzily(KVector, double)} with a default fuzzyness.
     *
     * @param other the vector to compare this vector to.
     * @return {@code true} if the vectors are approximately equal, {@code false} otherwise.
     */
    package func equalsFuzzily(_ other: KVector) -> Bool {
        return equalsFuzzily(other, KVector.defaultFuzziness)
    }
    
    /**
     * Compares if this and the given vector are approximately equal. What <i>approximately</i>
     * means is defined by the fuzzyness: for both x and y coordinate, the two vectors may only
     * differ by at most the fuzzyness to still be considered equal.
     *
     * @param other the vector to compare this vector to.
     * @param fuzzyness the maximum difference per dimension that is still considered equal.
     * @return {@code true} if the vectors are approximately equal, {@code false} otherwise.
     */
    package func equalsFuzzily(_ other: KVector, _ fuzzyness: Double) -> Bool {
        return abs(self.x - other.x) <= fuzzyness && abs(self.y - other.y) <= fuzzyness
    }
    
    /**
     * returns this vector's length.
     *
     * @return Math.sqrt(x*x + y*y)
     */
    package func length() -> Double {
        return sqrt(x * x + y * y)
    }
    
    /**
     * returns square length of this vector.
     *
     * @return x*x + y*y
     */
    package func squareLength() -> Double {
        return x * x + y * y
    }
    
    /**
     * Set vector to (0,0).
     *
     * @return {@code this}
     */
    @discardableResult
    package func reset() -> KVector {
        self.x = 0.0
        self.y = 0.0
        return self
    }
    
    /**
     * Resets this vector to the value of the other vector.
     *
     * @param other the vector whose values to copy.
     * @return {@code this}
     */
    @discardableResult
    package func set(_ other: KVector) -> KVector {
        self.x = other.x
        self.y = other.y
        return self
    }
    
    /**
     * Resets this vector to the given values.
     *
     * @param newX new x value.
     * @param newY new y value.
     * @return {@code this}
     */
    @discardableResult
    package func set(_ newX: Double, _ newY: Double) -> KVector {
        self.x = newX
        self.y = newY
        return self
    }
    
    /**
     * Vector addition.
     *
     * @param v vector to add
     * @return <code>this + v</code>
     */
    @discardableResult
    package func add(_ v: KVector) -> KVector {
        self.x += v.x
        self.y += v.y
        return self
    }
    
    /**
     * Translate the vector by adding the given amount.
     *
     * @param dx the x offset
     * @param dy the y offset
     * @return {@code this}
     */
    @discardableResult
    package func add(_ dx: Double, _ dy: Double) -> KVector {
        self.x += dx
        self.y += dy
        return self
    }
    
    /**
     * Returns the sum of arbitrarily many vectors as a new vector instance.
     *
     * @param vs vectors to be added
     * @return a new vector containing the sum of given vectors
     */
    package static func sum(_ vs: KVector...) -> KVector {
        let sum = KVector()
        for v in vs {
            sum.x += v.x
            sum.y += v.y
        }
        return sum
    }
    
    /**
     * Vector subtraction.
     *
     * @param v vector to subtract
     * @return {@code this}
     */
    @discardableResult
    package func sub(_ v: KVector) -> KVector {
        self.x -= v.x
        self.y -= v.y
        return self
    }
    
    /**
     * Translate the vector by subtracting the given amount.
     *
     * @param dx the x offset
     * @param dy the y offset
     * @return {@code this}
     */
    @discardableResult
    package func sub(_ dx: Double, _ dy: Double) -> KVector {
        self.x -= dx
        self.y -= dy
        return self
    }
    
    /**
     * Returns the difference of two vectors as a new vector instance.
     *
     * @param v1 the minuend
     * @param v2 the subtrahend
     * @return a new vector containing the difference of given vectors
     */
    package static func diff(_ v1: KVector, _ v2: KVector) -> KVector {
        return KVector(v1.x - v2.x, v1.y - v2.y)
    }
    
    /**
     * Scale the vector.
     *
     * @param scale scaling factor
     * @return {@code this}
     */
    @discardableResult
    package func scale(_ scale: Double) -> KVector {
        self.x *= scale
        self.y *= scale
        return self
    }
    
    /**
     * Scale the vector with different values for X and Y coordinate.
     *
     * @param scalex the x scaling factor
     * @param scaley the y scaling factor
     * @return {@code this}
     */
    @discardableResult
    package func scale(_ scalex: Double, _ scaley: Double) -> KVector {
        self.x *= scalex
        self.y *= scaley
        return self
    }
    
    /**
     * Normalize the vector.
     *
     * @return {@code this}
     */
    @discardableResult
    package func normalize() -> KVector {
        let length = self.length()
        if length > 0 {
            self.x /= length
            self.y /= length
        }
        return self
    }
    
    /**
     * scales this vector to the passed length.
     *
     * @param length length to scale to
     * @return {@code this}
     */
    @discardableResult
    package func scaleToLength(_ length: Double) -> KVector {
        self.normalize()
        self.scale(length)
        return self
    }
    
    /**
     * Negate the vector.
     *
     * @return {@code this}
     */
    @discardableResult
    package func negate() -> KVector {
        self.x = -self.x
        self.y = -self.y
        return self
    }
    
    /**
     * Returns angle representation of this vector in degree. The length of the vector must not be 0.
     *
     * @return value within [0,360)
     */
    package func toDegrees() -> Double {
        return toRadians().toDegrees()
    }
    
    /**
     * Returns angle representation of this vector in radians. The length of the vector must not be 0.
     *
     * @return value within [0,2*pi)
     */
    package func toRadians() -> Double {
        let length = self.length()
        guard length > 0 else { return 0 }
        
        if x >= 0 && y >= 0 {  // 1st quadrant
            return asin(y / length)
        } else if x < 0 {      // 2nd or 3rd quadrant
            return Double.pi - asin(y / length)
        } else {               // 4th quadrant
            return 2 * Double.pi + asin(y / length)
        }
    }
    
    /**
     * Add some "noise" to this vector.
     *
     * @param random the random number generator
     * @param amount the amount of noise to add
     */
    package func wiggle(_ random: inout some RandomNumberGenerator, _ amount: Double) {
        self.x += Double.random(in: 0..<1, using: &random) * amount - (amount / 2)
        self.y += Double.random(in: 0..<1, using: &random) * amount - (amount / 2)
    }
    
    /**
     * Returns the distance between two vectors.
     *
     * @param v2 second vector
     * @return distance between this and second vector
     */
    package func distance(_ v2: KVector) -> Double {
        let dx = self.x - v2.x
        let dy = self.y - v2.y
        return sqrt((dx * dx) + (dy * dy))
    }
    
    /**
     * Returns the dot product of the two given vectors.
     *
     * @param v2 second vector
     * @return this.x * v2.x + this.y * v2.y
     */
    package func dotProduct(_ v2: KVector) -> Double {
        return self.x * v2.x + self.y * v2.y
    }
    
    /**
     * Calculates the cross product of two vectors v and w.
     * @param v
     * @param w
     * @return the cross product of v and w
     */
    package static func crossProduct(_ v: KVector, _ w: KVector) -> Double {
        return v.x * w.y - v.y * w.x
    }
    
    /**
     * Rotates the given vector v by the angle provided in radians. Rotation is anti-clockwise.
     * @param angle
     * @return the rotated vector
     */
    @discardableResult
    package func rotate(_ angle: Double) -> KVector {
        let newX = self.x * cos(angle) - self.y * sin(angle)
        self.y = self.x * sin(angle) + self.y * cos(angle)
        self.x = newX
        return self
    }
    
    /**
     * Returns the angle between this vector and another given vector in radians.
     * @param other
     * @return angle between vectors
     */
    package func angle(_ other: KVector) -> Double {
        return acos(self.dotProduct(other) / (self.length() * other.length()))
    }
    
    /**
     * Apply the given bounds to this vector.
     *
     * @param lowx the lower bound for x coordinate
     * @param lowy the lower bound for y coordinate
     * @param highx the upper bound for x coordinate
     * @param highy the upper bound for y coordinate
     * @return {@code this}
     * @throws IllegalArgumentException if highx < lowx or highy < lowy
     */
    @discardableResult
    package func bound(_ lowx: Double, _ lowy: Double, _ highx: Double, _ highy: Double) throws -> KVector {
        guard highx >= lowx && highy >= lowy else {
            assertionFailure("The highx must be bigger then lowx and the highy must be bigger then lowy")
            return self
        }
        
        if x < lowx {
            self.x = lowx
        } else if x > highx {
            self.x = highx
        }
        
        if y < lowy {
            self.y = lowy
        } else if y > highy {
            self.y = highy
        }
        
        return self
    }
    
    /**
     * Determine whether any of the two values are NaN.
     *
     * @return true if x is NaN or y is NaN
     */
    package func isNaN() -> Bool {
        return x.isNaN || y.isNaN
    }
    
    /**
     * Determine whether any of the two values are infinite.
     *
     * @return true if x is infinite or y is infinite
     */
    package func isInfinite() -> Bool {
        return x.isInfinite || y.isInfinite
    }
    
    /**
     * Parse a string representation of a vector.
     *
     * @param string string representation of a vector
     */
    package func parse(_ string: String) throws {
        let chars = Array(string)
        var start = 0
        while start < chars.count && isDelimiter(chars[start]) {
            start += 1
        }
        
        var end = chars.count
        while end > 0 && isDelimiter(chars[end - 1]) {
            end -= 1
        }
        
        guard start < end else {
            throw ELK.Error.runtimeError("The given string does not contain any numbers.")
        }

        let substring = String(chars[start..<end])
        let tokens = substring.components(separatedBy: CharacterSet(charactersIn: ",;\"\r\n")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard tokens.count == 2 else {
            throw ELK.Error.runtimeError("Exactly two numbers are expected, \(tokens.count) were found.")
        }

        guard let newX = Double(tokens[0].trimmingCharacters(in: .whitespaces)),
              let newY = Double(tokens[1].trimmingCharacters(in: .whitespaces)) else {
            throw ELK.Error.runtimeError("The given string contains parts that cannot be parsed as numbers.")
        }
        
        self.x = newX
        self.y = newY
    }
    
    /**
     * Determine whether the given character is a delimiter.
     *
     * @param c a character
     * @return true if {@code c} is a delimiter
     */
    package func isDelimiter(_ c: Character) -> Bool {
        let delimiters: [Character] = [" ", "(", ")", "[", "]", "{", "}", "\"", "'", "\t", "\r", "\n"]
        return delimiters.contains(c)
    }

    // MARK: - Labeled convenience overloads

    @discardableResult
    package func add(x dx: Double, y dy: Double) -> KVector {
        return add(dx, dy)
    }

    @discardableResult
    package func sub(x dx: Double, y dy: Double) -> KVector {
        return sub(dx, dy)
    }

    @discardableResult
    package func set(x newX: Double, y newY: Double) -> KVector {
        return set(newX, newY)
    }

    @discardableResult
    package func scale(x scalex: Double, y scaley: Double) -> KVector {
        return scale(scalex, scaley)
    }

    // MARK: - Non-mutating convenience methods

    /// Returns the distance to another vector (labeled overload).
    package func distance(to v2: KVector) -> Double {
        return distance(v2)
    }

    /// Returns a new vector that is this vector plus another.
    package func added(to other: KVector) -> KVector {
        return KVector(self.x + other.x, self.y + other.y)
    }

    /// Returns a new vector that is this vector minus another.
    package func subtracted(by other: KVector) -> KVector {
        return KVector(self.x - other.x, self.y - other.y)
    }

    /// Returns a new vector scaled by a factor.
    package func scaled(by factor: Double) -> KVector {
        return KVector(self.x * factor, self.y * factor)
    }

    /// Returns a new vector scaled to a given length.
    package func scaledToLength(_ length: Double) -> KVector {
        let clone = self.clone()
        clone.scaleToLength(length)
        return clone
    }

    /// Labeled overload: scaleToLength(toLength:)
    @discardableResult
    package func scaleToLength(toLength length: Double) -> KVector {
        return scaleToLength(length)
    }
}
