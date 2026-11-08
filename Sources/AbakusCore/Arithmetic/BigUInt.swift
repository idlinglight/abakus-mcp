/// A non-negative integer of any size: little-endian 64-bit limbs, never with a zero limb on top (zero has no
/// limbs). Just the arithmetic exact decimal results need (`ExactDecimal`, ADR-0005); not a general library.
struct BigUInt: Sendable, Equatable, Comparable {
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
        var result = lhs.limbs
        var borrow: UInt64 = 0
        for i in 0..<result.count {
            let b = i < rhs.limbs.count ? rhs.limbs[i] : 0
            let (partial, overflow1) = result[i].subtractingReportingOverflow(b)
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[i] = difference
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return BigUInt(limbs: result)
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
