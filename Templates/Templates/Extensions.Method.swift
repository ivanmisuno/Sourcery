import Foundation
import SourceryRuntime

extension SourceryRuntime.Method {
    /// Constructs full method declaration string
    var methodDeclaration: String {
        var result = name
        if self.throws {
            result = result + " throws"
        } else if self.rethrows {
            result = result + " rethrows"
        }
        return result + " -> \(returnTypeName)"
    }

    /// Constructs method call string passing in parameters with their local names
    var methodCall: String {
        let params = parameters.map({
            if let label = $0.argumentLabel {
                return "\(label): \($0.name)"
            } else {
                return $0.name
            }
        }).joined(separator: ", ")
        var result = "decorated.\(callName)(\(params))"

        if self.throws {
            result = "try " + result
        }
        if !returnTypeName.isVoid {
            result = "return " + result
        }
        return result
    }
}
