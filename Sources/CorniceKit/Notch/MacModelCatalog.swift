import Foundation

/// Known model names and whether a model has a notch. Measure the actual geometry at
/// runtime; new models can fall back to the system's name.
public enum MacModelCatalog {
    public enum Family: String, Sendable, Equatable {
        case macBookAir13 = "MacBook Air 13″"
        case macBookAir15 = "MacBook Air 15″"
        case macBookPro14 = "MacBook Pro 14″"
        case macBookPro16 = "MacBook Pro 16″"
    }

    /// Notched Apple silicon laptops, keyed by `hw.model`.
    private static let notched: [String: Family] = {
        var map: [String: Family] = [:]
        for id in ["MacBookPro18,3", "MacBookPro18,4", "Mac14,5", "Mac14,9",
                   "Mac15,3", "Mac15,6", "Mac15,8", "Mac15,10",
                   "Mac16,1", "Mac16,6", "Mac16,8"] {
            map[id] = .macBookPro14
        }
        for id in ["MacBookPro18,1", "MacBookPro18,2", "Mac14,6", "Mac14,10",
                   "Mac15,7", "Mac15,9", "Mac15,11",
                   "Mac16,5", "Mac16,7"] {
            map[id] = .macBookPro16
        }
        for id in ["Mac14,2", "Mac15,12", "Mac16,12"] { map[id] = .macBookAir13 }
        for id in ["Mac14,15", "Mac15,13", "Mac16,13"] { map[id] = .macBookAir15 }
        return map
    }()

    /// The screen-size family for a model, or `nil` if the model is unknown to
    /// this build (including every desktop Mac and every Intel laptop).
    public static func family(forModelIdentifier identifier: String) -> Family? {
        notched[identifier]
    }

    /// This is only a hint for logging missing measurements. The measured display geometry
    /// takes priority.
    public static func expectsNotch(modelIdentifier: String) -> Bool {
        notched[modelIdentifier] != nil
    }

    /// Friendly name for a model identifier, or `nil` when unknown.
    public static func displayName(forModelIdentifier identifier: String) -> String? {
        notched[identifier]?.rawValue
    }
}
