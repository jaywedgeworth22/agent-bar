import Foundation

/// Two sentences in one user-visible string are separated by this, never by a
/// bare space.  A no-break space plus a space survives every renderer AppKit
/// hands it, and it is defined here so QuotaCore's error copy and the app's own
/// copy cannot drift apart.
public let sentenceGap = "\u{00A0} "

/// Cleans a token the way a person pastes one.
///
/// A token copied out of a shell export, a JSON file or a `.env` line arrives
/// wrapped in quotes, and a wrapped token is sent verbatim in the
/// `Authorization` header — which the server rejects as unauthorized, with
/// nothing on screen to suggest the quotes are the reason.  Whitespace is
/// trimmed first, then one matched pair of double or single quotes at a time,
/// trimming again between passes.  An unbalanced quote is left alone, because
/// it could be part of the credential.
public func sanitizedToken(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.count >= 2, let first = value.first, let last = value.last,
          first == last, first == "\"" || first == "'" {
        value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value
}
