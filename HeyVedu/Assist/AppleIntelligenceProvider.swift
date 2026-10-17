import Foundation
import FoundationModels

/// Apple's on-device model through FoundationModels: the private route, offered first.
/// Nothing leaves the Mac. The task's JSON Schema becomes a `DynamicGenerationSchema`, so
/// every task works here without a `@Generable` type of its own.
final class AppleIntelligenceProvider: AssistProvider {
    let id = AssistProviderID.apple
    let isLocal = true

    /// The on-device model sometimes repeats array items until the timeout; these keep a
    /// runaway answer short. Task answers are small JSON objects.
    static let maxResponseTokens = 600
    static let maxArrayItems = 10

    func availability() async -> AssistAvailability {
        guard #available(macOS 26, *) else { return .failed("Needs macOS 26 or later") }
        switch SystemLanguageModel.default.availability {
        case .available: return .available(version: nil)
        case .unavailable(.deviceNotEligible): return .failed("This Mac doesn't support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled): return .signedOut("Turn on Apple Intelligence in System Settings")
        case .unavailable(.modelNotReady): return .failed("The Apple Intelligence model is still downloading")
        case .unavailable: return .failed("Apple Intelligence is unavailable")
        }
    }

    func models() async throws -> [AssistModel] {
        [AssistModel(provider: .apple, id: "system", resolvedID: "system", displayName: "Apple Intelligence",
                     description: "On-device model; nothing leaves this Mac.")]
    }

    func run(_ call: AssistCall, route: AssistRoute) async throws -> AssistRawResult {
        guard #available(macOS 26, *) else { throw AssistError.unavailable("Needs macOS 26 or later") }
        guard case .available = SystemLanguageModel.default.availability else {
            throw AssistError.unavailable("Apple Intelligence is unavailable")
        }
        guard let object = try? JSONSerialization.jsonObject(with: call.schema) as? [String: Any],
              let schema = try? GenerationSchema(root: Self.schema(object, name: "Output"), dependencies: []) else {
            throw AssistError.badOutput("This task's schema can't run on Apple Intelligence")
        }
        let session = LanguageModelSession(model: SystemLanguageModel(useCase: .general), instructions: call.system)
        let started = ContinuousClock.now
        do {
            let response = try await withThrowingTaskGroup(of: GeneratedContent.self) { group in
                group.addTask {
                    try await session.respond(to: call.user, schema: schema, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.maxResponseTokens)).content
                }
                group.addTask {
                    try await Task.sleep(for: call.timeout)
                    throw AssistError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            return AssistRawResult(json: Data(response.jsonString.utf8), latency: started.duration(to: .now),
                                   inputTokens: nil, outputTokens: nil, costUSD: nil)
        } catch let error as AssistError {
            throw error
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests: throw AssistError.capacity("Apple Intelligence is busy")
            case .assetsUnavailable: throw AssistError.unavailable("Apple Intelligence model assets are unavailable")
            default: throw AssistError.badOutput("Apple Intelligence couldn't answer")
            }
        } catch is CancellationError {
            throw AssistError.cancelled
        } catch {
            throw AssistError.badOutput("Apple Intelligence couldn't answer")
        }
    }

    /// The subset of JSON Schema the tasks use: objects, arrays, strings (with enums),
    /// numbers, integers and booleans.
    @available(macOS 26, *)
    static func schema(_ json: [String: Any], name: String) -> DynamicGenerationSchema {
        switch json["type"] as? String {
        case "object":
            let required = Set(json["required"] as? [String] ?? [])
            let properties = (json["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(name: key, schema: schema(value as? [String: Any] ?? [:], name: "\(name)_\(key)"),
                                                 isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, properties: properties)
        case "array":
            return DynamicGenerationSchema(arrayOf: schema(json["items"] as? [String: Any] ?? [:], name: "\(name)_item"),
                                           maximumElements: json["maxItems"] as? Int ?? maxArrayItems)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            if let choices = json["enum"] as? [String] { return DynamicGenerationSchema(name: name, anyOf: choices) }
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
