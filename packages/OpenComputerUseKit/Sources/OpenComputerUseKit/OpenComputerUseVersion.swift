import Foundation

public let openComputerUseVersion = "0.3.0"

public func resolvedOpenComputerUseVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }

    return openComputerUseVersion
}

/// Reported in the `maka.cu/3` handshake so a host trace can name the exact
/// executor build. Populated at package time through the app bundle; a source
/// checkout has no commit to claim, and saying `unknown` is better than a value
/// the host would trust.
public func openComputerUseBuildCommit(bundle: Bundle = .main) -> String {
    guard let commit = bundle.object(forInfoDictionaryKey: "MakaCuBuildCommit") as? String,
          !commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return "unknown"
    }

    return commit
}
