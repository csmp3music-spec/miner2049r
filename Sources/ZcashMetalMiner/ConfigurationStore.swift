import Foundation

struct AppConfiguration: Codable {
    var selectedAlgorithm: MiningAlgorithm
    var poolURL: String
    var username: String
    var password: String
    var headerHex: String
    var batchSize: Double
    var hashesPerThread: Double
    var threadgroupMultiplier: Int
    var miningPipelineDepth: Int?
    var miningMemoryBudgetGB: Double?
    var miningCooldownMilliseconds: Double?
    var miningMaxJobAgeSeconds: Double?
    var externalMinerExecutable: String?
    var externalMinerArguments: String?
}

enum ConfigurationStore {
    private static var fileURL: URL {
        let directory = appSupportDirectory(named: "Miner2049er")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("config.json")
    }

    private static var legacyFileURL: URL {
        appSupportDirectory(named: "ZcashMetalMiner").appendingPathComponent("config.json")
    }

    static func load() -> AppConfiguration? {
        let activeURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : legacyFileURL
        guard let data = try? Data(contentsOf: activeURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    static func save(_ configuration: AppConfiguration) {
        guard let data = try? JSONEncoder.pretty.encode(configuration) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private static func appSupportDirectory(named name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
