// Invoke with /usr/bin/swift signing.swift; no secret is emitted, persisted, or passed in argv.
import Foundation
import Security
import CryptoKit
import Darwin

struct SigningFailure: Error { let message: String }
func fail(_ message: String) throws -> Never { throw SigningFailure(message: message) }
func publicKey(_ value: String) throws -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: value), data.count == 32 else {
        try fail("Expected a base64 Ed25519 public key (32 bytes)")
    }
    return try Curve25519.Signing.PublicKey(rawRepresentation: data)
}

func keyData(service: String, account: String, sparkle: Bool) throws -> Data {
    // Both controls are required: legacy login Keychain and modern authentication UI.
    let disabled = SecKeychainSetUserInteractionAllowed(false)
    guard disabled == errSecSuccess else { try fail("Cannot disable Keychain interaction (OSStatus \(disabled))") }
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
    ]
    if sparkle { query[kSecAttrProtocol as String] = kSecAttrProtocolSSH }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
        try fail("Existing signing key unavailable without UI: service=\(service), account=\(account), OSStatus=\(status); no retry, key creation, or ACL change performed")
    }
    guard let encoded = item as? Data, let text = String(data: encoded, encoding: .utf8) else {
        try fail("Existing signing key has an invalid encoding or length")
    }
    return try decodeKey(text, sparkle: sparkle)
}

func decodeKey(_ text: String, sparkle: Bool) throws -> Data {
    guard let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          decoded.count == 32 || (sparkle && decoded.count == 96) else {
        try fail("Existing signing key has an invalid encoding or length")
    }
    return decoded
}

func environmentKey(_ name: String) throws -> Data {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        try fail("Original signing key environment variable is unavailable")
    }
    return try decodeKey(value, sparkle: true)
}

func checkKey(_ key: Data, against publicValue: String) throws {
    let expected = try publicKey(publicValue).rawRepresentation
    let derived: Data
    if key.count == 32 {
        derived = try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation
    } else {
        derived = Data(key.suffix(32))
    }
    guard derived == expected else { try fail("Existing signing key does not match pinned public key; refusing rotation") }
}

func verify(publicValue: String, file: String, signature: String?) throws {
    let key = try publicKey(publicValue)
    var content = try Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe)
    let encoded: String
    if let signature {
        encoded = signature
    } else {
        // Sparkle 2.10 SPUExtractAppcastContent signs the bytes before the final signature block.
        let prefix = Data("<!-- sparkle-signatures:\n".utf8)
        guard let start = content.range(of: prefix, options: .backwards),
              let end = content.range(of: Data("-->".utf8), in: start.upperBound..<content.endIndex),
              let block = String(data: content[start.upperBound..<end.lowerBound], encoding: .utf8) else {
            try fail("Missing Sparkle feed signature block")
        }
        var fields: [String: String] = [:]
        for line in block.components(separatedBy: .newlines) {
            if let colon = line.firstIndex(of: ":") {
                fields[String(line[..<colon])] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let value = fields["edSignature"], let length = fields["length"],
              UInt64(length) == UInt64(start.lowerBound) else { try fail("Invalid Sparkle feed signature metadata") }
        encoded = value
        content = content.subdata(in: content.startIndex..<start.lowerBound)
    }
    guard let bytes = Data(base64Encoded: encoded), bytes.count == 64,
          key.isValidSignature(bytes, for: content) else { try fail("Ed25519 signature verification failed") }
}

func sign(signer: String, key: Data, publicValue: String, file: String) throws -> String {
    try checkKey(key, against: publicValue)
    guard !FileManager.default.fileExists(atPath: "-") else { try fail("Refusing ambiguous Sparkle stdin path: a file named - exists in the working directory") }
    let process = Process()
    process.environment = ["PATH": "/usr/bin:/bin"]
    process.executableURL = URL(fileURLWithPath: signer)
    process.arguments = ["--ed-key-file", "-", "-p", URL(fileURLWithPath: file).path]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    // Official tool can echo malformed key input in diagnostics; never relay it.
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data((key.base64EncodedString() + "\n").utf8))
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { try fail("Official Sparkle signing failed (exit \(process.terminationStatus)); output withheld") }
    let isFeed = file.lowercased().hasSuffix(".xml")
    let signature = String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try verify(publicValue: publicValue, file: file, signature: isFeed ? nil : signature)
    return isFeed ? "" : signature
}

func selftest(signer: String, account: String?, publicValue: String?) throws {
    let missingAccount = "noninteractive-selftest-" + UUID().uuidString
    do {
        _ = try keyData(service: "https://sparkle-project.org", account: missingAccount, sparkle: true)
        try fail("Selftest unexpectedly found a missing key")
    } catch let error as SigningFailure {
        guard error.message.contains("OSStatus=-25300") else { throw error }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("silent-signing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = directory.appendingPathComponent("payload.zip")
    let feed = directory.appendingPathComponent("appcast.xml")
    try Data("noninteractive signing selftest".utf8).write(to: payload)
    try Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Selftest</title></channel></rss>\n".utf8).write(to: feed)
    // Ephemeral test key exists only in memory, never in Keychain or on disk.
    let ephemeral = Curve25519.Signing.PrivateKey()
    let value = ephemeral.publicKey.rawRepresentation.base64EncodedString()
    let decoded = try decodeKey(ephemeral.rawRepresentation.base64EncodedString(), sparkle: true)
    try checkKey(decoded, against: value)
    do {
        _ = try decodeKey("invalid", sparkle: true)
        try fail("Selftest accepted malformed key")
    } catch let error as SigningFailure {
        guard error.message == "Existing signing key has an invalid encoding or length" else { throw error }
    }
    do {
        try checkKey(decoded, against: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        try fail("Selftest accepted a mismatched root")
    } catch let error as SigningFailure {
        guard error.message.contains("does not match pinned public key") else { throw error }
    }
    let signature = try sign(signer: signer, key: ephemeral.rawRepresentation, publicValue: value, file: payload.path)
    _ = try sign(signer: signer, key: ephemeral.rawRepresentation, publicValue: value, file: feed.path)
    try Data("tampered".utf8).write(to: payload)
    do {
        try verify(publicValue: value, file: payload.path, signature: signature)
        try fail("Selftest accepted tampering")
    } catch let error as SigningFailure {
        guard error.message == "Ed25519 signature verification failed" else { throw error }
    }
    print("PASS: no-UI missing-key error; official stdin archive/feed signing; public-only verification; tamper rejection")
    if let account, let publicValue {
        let key = try keyData(service: "https://sparkle-project.org", account: account, sparkle: true)
        try Data("existing root signing selftest".utf8).write(to: payload)
        _ = try sign(signer: signer, key: key, publicValue: publicValue, file: payload.path)
        print("PASS: existing signing root accessible without UI and signature verified")
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "check" where args.count == 3:
        try checkKey(keyData(service: "https://sparkle-project.org", account: args[1], sparkle: true), against: args[2])
        print("PASS: existing signing root matches pinned public key without UI")
    case "sign" where args.count == 5:
        let key = try keyData(service: "https://sparkle-project.org", account: args[2], sparkle: true)
        let signature = try sign(signer: args[1], key: key, publicValue: args[3], file: args[4])
        if !signature.isEmpty { print(signature) }
    case "verify" where args.count == 3 || args.count == 4:
        try verify(publicValue: args[1], file: args[2], signature: args.count == 4 ? args[3] : nil)
        print("PASS: public-key signature verification")
    case "check-service" where args.count == 4:
        try checkKey(keyData(service: args[1], account: args[2], sparkle: false), against: args[3])
        print(args[3])
    case "check-env" where args.count == 3:
        try checkKey(environmentKey(args[1]), against: args[2])
        print(args[2])
    case "sign-env" where args.count == 5:
        let signature = try sign(signer: args[1], key: environmentKey(args[2]), publicValue: args[3], file: args[4])
        if !signature.isEmpty { print(signature) }
    case "sign-stdin" where args.count == 4:
        let key = try keyData(service: args[1], account: args[2], sparkle: false)
        try checkKey(key, against: args[3])
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
        print(try privateKey.signature(for: FileHandle.standardInput.readDataToEndOfFile()).base64EncodedString())
    case "selftest" where args.count == 2 || args.count == 4:
        try selftest(signer: args[1], account: args.count == 4 ? args[2] : nil, publicValue: args.count == 4 ? args[3] : nil)
    default:
        try fail("Usage: signing.swift check ACCOUNT PUBLIC_KEY | sign SIGN_UPDATE ACCOUNT PUBLIC_KEY FILE | verify PUBLIC_KEY FILE [SIGNATURE] | check-service SERVICE ACCOUNT PUBLIC_KEY | sign-stdin SERVICE ACCOUNT PUBLIC_KEY | check-env ENV_NAME PUBLIC_KEY | sign-env SIGN_UPDATE ENV_NAME PUBLIC_KEY FILE | selftest SIGN_UPDATE [ACCOUNT PUBLIC_KEY]")
    }
} catch let error as SigningFailure {
    fputs("BLOCKED: \(error.message)\n", stderr)
    exit(1)
} catch {
    // Errors from platform libraries may contain input data; only the safe category is displayed.
    fputs("BLOCKED: signing helper platform or file operation failed; details withheld\n", stderr)
    exit(1)
}
