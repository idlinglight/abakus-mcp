/// A non-negative integer of any size: little-endian 64-bit limbs, never with a zero limb on top (zero has no
/// limbs). Just the arithmetic exact decimal results (`ExactDecimal`, ADR-0005) and exact fractions (`Fraction`,
/// ADR-0007) need; not a general library.
struct BigUInt: Sendable, Equatable, Comparable, CustomStringConvertible {
    private(set) var limbs: [UInt64]

    static let zero = BigUInt(limbs: [])
    static let one = BigUInt(1)

    init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    /// Reads ASCII digit values (0...9), most significant first.
    init(digits: some Collection<UInt8>) {
        var value = BigUInt.zero
        var chunk: UInt64 = 0
        var chunkLength = 0
        for digit in digits {
            chunk = chunk * 10 + UInt64(digit)
            chunkLength += 1
            if chunkLength == 19 {
                value = value.multiplied(by: BigUInt.powersOfTen[19]) + BigUInt(chunk)
                chunk = 0
                chunkLength = 0
            }
        }
        if chunkLength > 0 {
            value = value.multiplied(by: BigUInt.powersOfTen[chunkLength]) + BigUInt(chunk)
        }
        self = value
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }


    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result: [UInt64] = []
        result.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let a = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (partial, overflow1) = a.addingReportingOverflow(b)
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result.append(sum)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    /// `lhs - rhs`; `lhs` must not be smaller than `rhs`.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction below zero")
        var result = lhs
        result.subtract(rhs)
        return result
    }

    func multiplied(by other: BigUInt) -> BigUInt {
        if isZero || other.isZero { return .zero }
        var result = [UInt64](repeating: 0, count: limbs.count + other.limbs.count)
        for i in 0..<limbs.count {
            var carry: UInt64 = 0
            for j in 0..<other.limbs.count {
                let (high, low) = limbs[i].multipliedFullWidth(by: other.limbs[j])
                let (partial, overflow1) = result[i + j].addingReportingOverflow(low)
                let (sum, overflow2) = partial.addingReportingOverflow(carry)
                result[i + j] = sum
                // a*b + c + d < 2^128 for 64-bit a, b, c, d, so this never overflows.
                carry = high + (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            }
            result[i + other.limbs.count] = carry
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.multiplied(by: rhs)
    }

    /// `self × 10^exponent`.
    func timesPowerOfTen(_ exponent: Int) -> BigUInt {
        precondition(exponent >= 0)
        var result = self
        var remaining = exponent
        while remaining >= 19 {
            result = result.multiplied(by: BigUInt.powersOfTen[19])
            remaining -= 19
        }
        return remaining > 0 ? result.multiplied(by: BigUInt.powersOfTen[remaining]) : result
    }

    static func powerOfTen(_ exponent: Int) -> BigUInt {
        BigUInt.one.timesPowerOfTen(exponent)
    }

    /// Division by a single limb.
    func quotientAndRemainder(dividingBy divisor: UInt64) -> (quotient: BigUInt, remainder: UInt64) {
        precondition(divisor != 0, "BigUInt division by zero")
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            (quotient[i], remainder) = divisor.dividingFullWidth((high: remainder, low: limbs[i]))
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    /// Long division, one bit at a time. The numbers here stay below a few thousand bits, so that is fast enough.
    func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt division by zero")
        if self < divisor { return (.zero, self) }
        if divisor.limbs.count == 1 {
            let (quotient, remainder) = quotientAndRemainder(dividingBy: divisor.limbs[0])
            return (quotient, BigUInt(remainder))
        }
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder = BigUInt.zero
        for bit in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder.shiftLeftOne(insertingBit: (limbs[bit / 64] >> UInt64(bit % 64)) & 1)
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    private mutating func shiftLeftOne(insertingBit bit: UInt64) {
        var carry = bit
        for i in 0..<limbs.count {
            let next = limbs[i] >> 63
            limbs[i] = (limbs[i] << 1) | carry
            carry = next
        }
        if carry != 0 { limbs.append(carry) }
    }

    /// The number of decimal digits; 0 for zero.
    var decimalDigitCount: Int {
        if isZero { return 0 }
        var value = self
        var count = 0
        while value.limbs.count > 1 {
            value = value.quotientAndRemainder(dividingBy: BigUInt.powersOfTen[19].limbs[0]).quotient
            count += 19
        }
        var top = value.limbs.first ?? 0
        while top > 0 {
            top /= 10
            count += 1
        }
        return count
    }

    /// `(self / 10^k, k)` for the largest `k` that leaves no remainder.
    func strippingTrailingDecimalZeros() -> (value: BigUInt, zeros: Int) {
        if isZero { return (self, 0) }
        var value = self
        var zeros = 0
        while true {
            let (quotient, remainder) = value.quotientAndRemainder(dividingBy: 10)
            if remainder != 0 { return (value, zeros) }
            value = quotient
            zeros += 1
        }
    }

    /// The decimal digits, most significant first; "0" for zero.
    var description: String {
        if isZero { return "0" }
        let chunkSize = BigUInt.powersOfTen[19].limbs[0]
        var chunks: [UInt64] = []
        var value = self
        while !value.isZero {
            let (quotient, remainder) = value.quotientAndRemainder(dividingBy: chunkSize)
            chunks.append(remainder)
            value = quotient
        }
        var text = String(chunks.removeLast())
        for chunk in chunks.reversed() {
            let digits = String(chunk)
            text += String(repeating: "0", count: 19 - digits.count) + digits
        }
        return text
    }

    // MARK: Greatest common divisor

    /// The greatest common divisor; `gcd(0, x)` is `x`. Binary GCD (Stein's algorithm): subtractions and shifts,
    /// because Euclid's algorithm on the bitwise long division above would be far too slow for numbers of thousands
    /// of digits. When one number is much longer than the other, one division first brings it down to size.
    static func gcd(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var (u, v) = a >= b ? (a, b) : (b, a)
        if v.isZero { return u }
        if v.limbs.count == 1 {
            // The common case of a small denominator: one pass for the remainder, then 64-bit numbers.
            var x = v.limbs[0]
            var y = u.remainder(dividingBy: x)
            while y != 0 { (x, y) = (y, x % y) }
            return BigUInt(x)
        }
        if u.limbs.count >= 3 * v.limbs.count {
            // The division costs about bits(u) × limbs(v); the subtractions it saves, bits(u) × limbs(u).
            u = u.quotientAndRemainder(dividingBy: v).remainder
            if u.isZero { return v }
        }
        let commonZeros = min(u.trailingZeroBitCount, v.trailingZeroBitCount)
        u.shiftRight(by: u.trailingZeroBitCount)
        v.shiftRight(by: v.trailingZeroBitCount)
        // Both odd from here on. Their difference is even, and halving it keeps the gcd, which is odd.
        while u != v {
            if u < v { swap(&u, &v) }
            u.subtract(v)
            u.shiftRight(by: u.trailingZeroBitCount)
        }
        return commonZeros == 0 ? u : u.multiplied(by: BigUInt.powerOfTwo(commonZeros))
    }

    var trailingZeroBitCount: Int {
        guard let index = limbs.firstIndex(where: { $0 != 0 }) else { return 0 }
        return index * 64 + limbs[index].trailingZeroBitCount
    }

    static func powerOfTwo(_ exponent: Int) -> BigUInt {
        BigUInt(limbs: [UInt64](repeating: 0, count: exponent / 64) + [1 << UInt64(exponent % 64)])
    }

    /// `self % divisor` for a single limb, without building the quotient.
    private func remainder(dividingBy divisor: UInt64) -> UInt64 {
        precondition(divisor != 0, "BigUInt division by zero")
        var remainder: UInt64 = 0
        for limb in limbs.reversed() {
            remainder = divisor.dividingFullWidth((high: remainder, low: limb)).remainder
        }
        return remainder
    }

    /// `self -= other` in place; `self` must not be smaller.
    private mutating func subtract(_ other: BigUInt) {
        var borrow: UInt64 = 0
        for i in 0..<limbs.count {
            if i >= other.limbs.count && borrow == 0 { break }
            let b = i < other.limbs.count ? other.limbs[i] : 0
            let (partial, overflow1) = limbs[i].subtractingReportingOverflow(b)
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            limbs[i] = difference
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        precondition(borrow == 0, "BigUInt subtraction below zero")
        while limbs.last == 0 { limbs.removeLast() }
    }

    /// `self >>= bits` in place.
    private mutating func shiftRight(by bits: Int) {
        let limbShift = min(bits / 64, limbs.count)
        let bitShift = UInt64(bits % 64)
        if limbShift > 0 { limbs.removeFirst(limbShift) }
        if bitShift > 0 {
            for i in 0..<limbs.count {
                let carried = i + 1 < limbs.count ? limbs[i + 1] << (64 - bitShift) : 0
                limbs[i] = (limbs[i] >> bitShift) | carried
            }
        }
        while limbs.last == 0 { limbs.removeLast() }
    }

    /// 10^0 ... 10^19, the powers of ten that fit one limb.
    private static let powersOfTen: [BigUInt] = {
        var powers: [BigUInt] = []
        var power: UInt64 = 1
        for exponent in 0...19 {
            powers.append(BigUInt(power))
            if exponent < 19 { power *= 10 }
        }
        return powers
    }()
}
