import Foundation
import SottoAPI
import SottoServerKit

@main
struct SottoServerMain {
    static func main() async throws {
        if CommandLine.arguments.contains("--print-default-proofreading-prompt") {
            print(ServerPreferences.defaultProofreadingPrompt)
            return
        }
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(ServerConfiguration.usage)
            return
        }
        let configuration = try ServerConfiguration.parse()
        try await SottoHTTPServer.run(configuration: configuration)
    }
}
