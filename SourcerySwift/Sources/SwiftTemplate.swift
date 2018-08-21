//
//  SwiftTemplate.swift
//  Sourcery
//
//  Created by Krunoslav Zaher on 12/30/16.
//  Copyright © 2016 Pixle. All rights reserved.
//

import Foundation
import PathKit
import SourceryRuntime

private enum Delimiters {
    static let open = "<%"
    static let close = "%>"
}

private struct ProcessResult {
    let output: String
    let error: String
}

private struct ParsedTemplate {
    /// Paths to source Swift files referred to by `<%- import("") -%>` commands
    let imports: [Path]
    /// The immediate code extracted from the template file
    let code: String
}

open class SwiftTemplate {

    public let sourcePath: Path
    let cachePath: Path?
    fileprivate let parsedTemplate: ParsedTemplate

    private lazy var buildDir: Path = {
        guard let tempDirURL = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SwiftTemplate.build") else { fatalError("Unable to get temporary path") }
        _ = try? FileManager.default.removeItem(at: tempDirURL)
        // swiftlint:disable:next force_try
        try! FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true, attributes: nil)
        return Path(tempDirURL.path)
    }()

    public init(path: Path, cachePath: Path? = nil) throws {
        self.sourcePath = path
        self.cachePath = cachePath
        self.parsedTemplate = try SwiftTemplate.parse(sourcePath: path)
    }

    private enum Command {
        case `import`(Path)
        case output(String)
        case controlFlow(String)
        case outputEncoded(String)
    }

    fileprivate static func parse(sourcePath: Path) throws -> ParsedTemplate {

        let commands = try SwiftTemplate.parseCommands(in: sourcePath)

        var imports = [Path]()
        var outputFile = [String]()

        for command in commands {
            switch command {
            case let .import(path):
                imports.append(path)
            case let .output(code):
                outputFile.append("print(\"\\(" + code + ")\", terminator: \"\");")
            case let .controlFlow(code):
                outputFile.append("\(code)")
            case let .outputEncoded(code):
                if !code.isEmpty {
                    outputFile.append(("print(\"") + code.stringEncoded + "\", terminator: \"\");")
                }
            }
        }

        let contents = outputFile.joined(separator: "\n")
        let code = """
        import Foundation
        import SourceryRuntime

        extension TemplateContext {
            func generate() throws {
                \(contents)
            }
        }

        do {
            try ProcessInfo().context!.generate()
        } catch {
            Log.error(error)
        }
        """

        return ParsedTemplate(imports: imports, code: code)
    }

    private static let regexInclude = try! NSRegularExpression(pattern: "include\\(\"([^\"]*)\"\\)", options: [])
    private static let regexImport = try! NSRegularExpression(pattern: "import\\(\"([^\"]*)\"\\)", options: [])

    private static func parseCommands(in sourcePath: Path, includeStack: [Path] = []) throws -> [Command] {
        let templateContent = try "<%%>" + sourcePath.read()

        let components = templateContent.components(separatedBy: Delimiters.open)

        var processedComponents = [String]()
        var commands = [Command]()

        let currentLineNumber = {
            // the following +1 is to transform a line count (starting from 0) to a line number (starting from 1)
            return processedComponents.joined(separator: "").numberOfLineSeparators + 1
        }

        for component in components.suffix(from: 1) {
            guard let endIndex = component.range(of: Delimiters.close) else {
                throw "\(sourcePath):\(currentLineNumber()) Error while parsing template. Unmatched <%"
            }

            var code = String(component[..<endIndex.lowerBound])
            let shouldTrimTrailingNewLines = code.trimSuffix("-")
            let shouldTrimLeadingWhitespaces = code.trimPrefix("_")
            let shouldTrimTrailingWhitespaces = code.trimSuffix("_")

            // string after closing tag
            var encodedPart = String(component[endIndex.upperBound...])
            if shouldTrimTrailingNewLines {
                // we trim only new line caused by script tag, not all of leading new lines in string after tag
                encodedPart = encodedPart.replacingOccurrences(of: "^\\n{1}", with: "", options: .regularExpression, range: nil)
            }
            if shouldTrimTrailingWhitespaces {
                // trim all leading whitespaces in string after tag
                encodedPart = encodedPart.replacingOccurrences(of: "^[\\h\\t]*", with: "", options: .regularExpression, range: nil)
            }
            if shouldTrimLeadingWhitespaces {
                if case .outputEncoded(let code)? = commands.last {
                    // trim all trailing white spaces in previously enqued code string
                    let trimmed = code.replacingOccurrences(of: "[\\h\\t]*$", with: "", options: .regularExpression, range: nil)
                    _ = commands.popLast()
                    commands.append(.outputEncoded(trimmed))
                }
            }

            if code.trimPrefix("-") {

                var appendSourcePathAndLineNumberToError = true
                do {
                    if let includePath = try extractIncludedFilePath(code: code, regex: regexInclude, sourcePath: sourcePath, defaultExtensionIfOmitted: "swifttemplate") {
                        // Check for include cycles to prevent stack overflow and show a more user friendly error
                        if includeStack.contains(includePath) {
                            throw "Include cycle detected for \(includePath). Check your include statements so that templates do not include each other."
                        }

                        appendSourcePathAndLineNumberToError = false // Don't modify the error if thrown from the recursive call to `parseCommands` - it's already adorned with sourcePath:lineNumber information.
                        let includedCommands = try SwiftTemplate.parseCommands(in: includePath, includeStack: includeStack + [includePath])
                        commands.append(contentsOf: includedCommands)
                    } else if let importPath = try extractIncludedFilePath(code: code, regex: regexImport, sourcePath: sourcePath, defaultExtensionIfOmitted: "swift") {
                        commands.append(.import(importPath))
                    } else {
                        throw "The tag starting with `<%-` must contain either `include(\"\")` or `import(\"\")` command, have: '\(code)'"
                    }
                } catch {
                    if appendSourcePathAndLineNumberToError {
                        throw "\(sourcePath):\(currentLineNumber()) Error: \(error)"
                    } else {
                        throw error
                    }
                }

            } else if code.trimPrefix("=") {
                commands.append(.output(code))
            } else {
                if !code.hasPrefix("#") && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    commands.append(.controlFlow(code))
                }
            }

            if !encodedPart.isEmpty {
                commands.append(.outputEncoded(encodedPart))
            }
            processedComponents.append(component)
        }

        return commands
    }

    private static func extractIncludedFilePath(code: String, regex: NSRegularExpression, sourcePath: Path, defaultExtensionIfOmitted: String? = nil) throws -> Path? {
        guard let match = regex.firstMatch(in: code, options: [], range: code.bridge().entireRange) else {
            return nil
        }
        let includedFile = code.bridge().substring(with: match.range(at: 1))
        var includePath = Path(components: [sourcePath.parent().string, includedFile])
        // The template extension may be omitted, so try to read again by adding it if a template was not found
        if !includePath.exists, let defaultExtensionIfOmitted = defaultExtensionIfOmitted, includePath.extension != defaultExtensionIfOmitted {
            includePath = Path(includePath.string + ".\(defaultExtensionIfOmitted)")
        }
        guard includePath.exists else {
            throw "File \(includePath) does not exist!"
        }
        return includePath
    }

    public func render(_ context: Any) throws -> String {
        let binaryPath: Path

        if let cachePath = cachePath,
            let hash = try parsedTemplate.sha256(),
            let hashPath = hash.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) {

            binaryPath = cachePath + hashPath
            if !binaryPath.exists {
                try? cachePath.delete() // clear old cache
                try cachePath.mkdir()
                try build().move(binaryPath)
                try copyFramework(to: cachePath.parent())
            }
        } else {
            try binaryPath = build()
        }

        let serializedContextPath = buildDir + "context.bin"
        let data = NSKeyedArchiver.archivedData(withRootObject: context)
        try serializedContextPath.write(data)

        let result = try Process.runCommand(path: binaryPath.description,
                                            arguments: [serializedContextPath.description])

        if !result.error.isEmpty {
            throw "\(sourcePath): \(result.error)"
        }

        return result.output
    }

    func build() throws -> Path {
        let mainFile = buildDir + Path("main.swift")
        let binaryFile = buildDir + Path("bin")

        try copyFramework(to: buildDir.parent())
        try mainFile.write(parsedTemplate.code)
        let sourceFiles = try copy(importedFiles: parsedTemplate.imports, to: buildDir)

        let arguments = [
            [mainFile.description],
            sourceFiles.map { $0.description },
            [
                "-suppress-warnings",
                "-Onone",
                "-module-name", "main",
                "-target", "x86_64-apple-macosx10.11",
                "-F", buildDir.parent().description,
                "-o", binaryFile.description,
                "-Xlinker", "-headerpad_max_install_names"
            ]
        ].flatMap { $0 }

        let compilationResult = try Process.runCommand(path: "/usr/bin/swiftc",
                                                       arguments: arguments)

        if !compilationResult.error.isEmpty {
            throw compilationResult.error
        }

        let linkingResult = try Process.runCommand(path: "/usr/bin/install_name_tool",
                                                   arguments: [
                                                    "-add_rpath",
                                                    "@executable_path/../",
                                                    binaryFile.description])
        if !linkingResult.error.isEmpty {
            throw linkingResult.error
        }

        try? mainFile.delete()

        return binaryFile
    }

    private func copyFramework(to path: Path) throws {
        let sourceryFramework = SwiftTemplate.frameworksPath + "SourceryRuntime.framework"

        let copyFramework = try Process.runCommand(path: "/usr/bin/rsync", arguments: [
            "-av",
            "--force",
            sourceryFramework.description,
            path.description
            ])

        if !copyFramework.error.isEmpty {
            throw copyFramework.error
        }
    }

    private func copy(importedFiles files: [Path], to directory: Path) throws -> [Path] {
        return try files.map { file in
            let destinationPath = Path(components: [directory.string, file.lastComponent])
            try file.copy(destinationPath)
            return destinationPath
        }
    }

}

fileprivate extension SwiftTemplate {

    static var frameworksPath: Path {
        return Path(Bundle(for: SwiftTemplate.self).bundlePath +  "/Versions/Current/Frameworks")
    }

}

// swiftlint:disable:next force_try
private let newlines = try! NSRegularExpression(pattern: "\\n\\r|\\r\\n|\\r|\\n", options: [])

private extension String {
    var numberOfLineSeparators: Int {
        return newlines.matches(in: self, options: [], range: NSRange(location: 0, length: self.count)).count
    }

    var stringEncoded: String {
        return self.unicodeScalars.map { x -> String in
            return x.escaped(asASCII: true)
            }.joined(separator: "")
    }
}

private extension Process {
    static func runCommand(path: String, arguments: [String], environment: [String: String] = [:]) throws -> ProcessResult {
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        task.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        let outHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        Log.verbose(path + " " + arguments.map { "\"\($0)\"" }.joined(separator: " "))
        task.launch()

        let outputData = outHandle.readDataToEndOfFile()
        let errorData = errorHandle.readDataToEndOfFile()
        outHandle.closeFile()
        errorHandle.closeFile()

        task.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        if task.terminationReason != .exit {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1, userInfo: [
                "terminationReason": task.terminationReason,
                "error": error
                ])
        }

        return ProcessResult(output: output, error: error)
    }
}

extension String {
    func bridge() -> NSString {
        #if os(Linux)
            return NSString(string: self)
        #else
            return self as NSString
        #endif
    }
}

extension ParsedTemplate {
    func sha256() throws -> String? {
        let importedFilesContents = try imports.reduce(into: "") { (partialResult: inout String, nextFile: Path) in
            partialResult.append(try nextFile.read())
        }
        let concatenatedCodeAndImportedFileContents = code.appending(importedFilesContents)
        return concatenatedCodeAndImportedFileContents.sha256()
    }
}
