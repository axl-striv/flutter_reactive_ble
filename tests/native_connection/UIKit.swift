// Only the application lifecycle boundary is simulated; Central's guards are real.
public final class UIApplication {
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState: State = .active
}
