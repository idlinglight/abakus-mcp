/// Stateless arithmetic tools: sum (ADR-0005) and calc (ADR-0007).
public enum ArithmeticTools {
    public static let all: [any Tool] = [SumTool(), CalcTool()]
}
