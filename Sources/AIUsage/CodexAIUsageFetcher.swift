import Foundation

enum CodexAIValidators {
    static func isValidAccessToken(_ accessToken: String) -> Bool {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard parts[0].hasPrefix("eyJ") else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty else { return false }
            return part.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            }
        }
    }

    static func isValidAccountId(_ accountId: String) -> Bool {
        let value = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }
        if value.lowercased() == "null" { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value != 0x7F
        }
    }
}

enum CodexAIUsageFetcher {
    static let fetch: @Sendable (AIUsageSecret) async throws -> AIUsageWindows = { secret in
        guard let token = secret.fields["accessToken"], CodexAIValidators.isValidAccessToken(token) else {
            throw CodexAIUsageFetchError.invalidAccessToken
        }
        let accountId = secret.fields["accountId"] ?? ""
        guard CodexAIValidators.isValidAccountId(accountId) else {
            throw CodexAIUsageFetchError.invalidAccountId
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexAIUsageFetchError.badResponse
        }

        var headers: [String: String] = ["Authorization": "Bearer \(token)"]
        if !accountId.isEmpty {
            headers["chatgpt-account-id"] = accountId
        }

        let session = AIUsageHTTP.makeSession(timeout: 10)
        defer { session.invalidateAndCancel() }

        let payload: [String: Any]
        do {
            payload = try await AIUsageHTTP.getJSONObject(url: url, headers: headers, session: session)
        } catch let error as AIUsageHTTPError {
            switch error {
            case .http(let code) where code == 401 || code == 403:
                throw CodexAIUsageFetchError.httpAuth(code)
            case .http(404):
                throw CodexAIUsageFetchError.http404
            case .http(let code):
                throw CodexAIUsageFetchError.http(code)
            case .badResponse:
                throw CodexAIUsageFetchError.badResponse
            case .decoding:
                throw CodexAIUsageFetchError.decoding
            case .network:
                throw CodexAIUsageFetchError.network
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAIUsageFetchError.network
        }

        return try parseWindows(payload: payload)
    }

    static func parseWindows(payload: [String: Any]) throws -> AIUsageWindows {
        guard let rateLimit = payload["rate_limit"] as? [String: Any] else {
            throw CodexAIUsageFetchError.decoding
        }
        let session5h = try parseWindow(rateLimit["primary_window"] as? [String: Any])
        let session7d: AIUsageWindow
        if let secondaryRaw = rateLimit["secondary_window"] as? [String: Any] {
            session7d = try parseWindow(secondaryRaw)
        } else {
            session7d = AIUsageWindow(utilization: 0, resetsAt: nil, windowSeconds: 604_800)
        }
        return AIUsageWindows(session: session5h, week: session7d)
    }

    static func parseWindow(_ raw: [String: Any]?) throws -> AIUsageWindow {
        guard let raw else { throw CodexAIUsageFetchError.decoding }

        let utilization = try parseUtilization(raw["used_percent"])

        guard let limit = raw["limit_window_seconds"] as? NSNumber else {
            throw CodexAIUsageFetchError.decoding
        }
        let windowSeconds = limit.doubleValue
        guard windowSeconds > 0 else {
            throw CodexAIUsageFetchError.decoding
        }

        let resetsAt: Date?
        if let after = raw["reset_after_seconds"] as? NSNumber {
            let value = after.doubleValue
            if value < 0 {
                throw CodexAIUsageFetchError.decoding
            }
            resetsAt = Date(timeIntervalSinceNow: value)
        } else if raw["reset_after_seconds"] == nil
                || raw["reset_after_seconds"] is NSNull {
            resetsAt = nil
        } else {
            throw CodexAIUsageFetchError.decoding
        }

        return AIUsageWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowSeconds: windowSeconds
        )
    }

    private static func parseUtilization(_ raw: Any?) throws -> Int {
        if raw == nil || raw is NSNull { throw CodexAIUsageFetchError.decoding }
        if raw is Bool { throw CodexAIUsageFetchError.decoding }
        if let int = raw as? Int {
            return clamp(int)
        }
        if let number = raw as? NSNumber {
            let double = number.doubleValue
            if double != Double(Int(double)) {
                throw CodexAIUsageFetchError.decoding
            }
            return clamp(Int(double))
        }
        throw CodexAIUsageFetchError.decoding
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
