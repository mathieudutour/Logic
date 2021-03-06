//
//  Compiler+Evaluate.swift
//  Logic
//
//  Created by Devin Abbott on 5/30/19.
//  Copyright © 2019 BitDisco, Inc. All rights reserved.
//

import Foundation
import Colors
import class SwiftGraph.UnweightedGraph

private extension Color {
    var rgbaString: String {
        let r = Int(rgb.red * 255)
        let g = Int(rgb.green * 255)
        let b = Int(rgb.blue * 255)
        let a = round(alpha * 100) / 100
        return "rgba(\(r),\(g),\(b),\(a))"
    }

    var cssString: String {
        return alpha < 1 ? rgbaString : hexString.uppercased()
    }

    init(cssString: String) {
        let cssColor = parseCSSColor(cssString) ?? CSSColor(0, 0, 0, 0)
        var colorValue = Color(redInt: cssColor.r, greenInt: cssColor.g, blueInt: cssColor.b)
        colorValue.alpha = Float(cssColor.a)
        self = colorValue
    }
}

private extension NSColor {
    var hexString: String {
        guard let rgbColor = usingColorSpaceName(NSColorSpaceName.calibratedRGB) else {
            return "#FFFFFF"
        }
        let red = Int(round(rgbColor.redComponent * 0xFF))
        let green = Int(round(rgbColor.greenComponent * 0xFF))
        let blue = Int(round(rgbColor.blueComponent * 0xFF))
        let hexString = NSString(format: "#%02X%02X%02X", red, green, blue)
        return hexString as String
    }

    var rgbaString: String {
        guard let rgbColor = usingColorSpaceName(NSColorSpaceName.calibratedRGB) else {
            return "rgba(255,255,255,1)"
        }
        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        let rgbaString = "rgba(\(red),\(green),\(blue),\(alphaComponent))"
        return rgbaString as String
    }

    var cssString: String {
        guard let _ = usingColorSpaceName(NSColorSpaceName.calibratedRGB) else {
            return "#FFFFFF"
        }
        return alphaComponent < 1 ? rgbaString : hexString
    }
}

extension Compiler {
    public struct EvaluationThunk {
        public init(label: String? = nil, dependencies: [UUID] = [], _ f: @escaping ([LogicValue]) -> LogicValue) {
            self.label = label
            self.dependencies = dependencies
            self.f = f
        }

        public var label: String?
        public var dependencies: [UUID]
        public var f: ([LogicValue]) -> LogicValue
    }

    public class EvaluationContext {
        public init(values: [UUID: LogicValue] = [:], thunks: [UUID: EvaluationThunk] = [:]) {
            self.values = values
            self.thunks = thunks
        }

        private var values: [UUID: LogicValue]
        public var thunks: [UUID: EvaluationThunk]

        public var cycles: [[UUID]] {
            if let cycles = cachedCycles {
                return cycles
            }

            let cycles = detectCycles()
            cachedCycles = cycles
            return cycles
        }

        public var hasCycle: Bool {
            return !cycles.isEmpty
        }

        private var cachedCycles: [[UUID]]?

        private func detectCycles() -> [[UUID]] {
            let graph = UnweightedGraph<UUID>()

            thunks.keys.forEach { key in
                _ = graph.addVertex(key)
            }

            thunks.forEach { (arg) in
                let (uuid, thunk) = arg
                thunk.dependencies.forEach { dependency in
                    graph.addEdge(from: uuid, to: dependency, directed: true)
                }
            }

            return graph.detectCycles()
        }

        public func add(uuid: UUID, _ thunk: EvaluationThunk) {
            thunks[uuid] = thunk
        }

        public func evaluate(uuid: UUID, logLevel: StandardConfiguration.LogLevel = .none) -> LogicValue? {
            if hasCycle && cycles.joined().contains(uuid) {
                return nil
            }

            if let value = values[uuid] {
                return value
            }

            if let thunk = thunks[uuid] {
                if logLevel == .verbose, let label = thunk.label {
                    Swift.print("Evaluate thunk: \(label) \(uuid) - [\(thunk.dependencies.map { $0.uuidString }.joined(separator: ", "))]")
                }

                let resolvedDependencies = thunk.dependencies.map { evaluate(uuid: $0, logLevel: logLevel) }

                if let index = resolvedDependencies.firstIndex(where: { $0 == nil }) {
                    if logLevel == .verbose, let label = thunk.label {
                        Swift.print("Evaluate thunk: \(label) - FAILED")

                        let unresolved = thunk.dependencies[index]
                        if let unresolvedThunk = thunks[unresolved] {
                            Swift.print("Unresolved thunk", unresolvedThunk.label ?? "")
                        } else {
                            Swift.print("Missing thunk", unresolved)
                        }
                    }

                    return nil
                } else {
                    if logLevel == .verbose, let label = thunk.label {
                        Swift.print("Evaluate thunk: \(label) - SUCCESS")
                    }
                }
                let result = thunk.f(resolvedDependencies.compactMap { $0 })
                values[uuid] = result
                return result
            }

            return nil
        }
    }

    public typealias EvaluationResult = Result<EvaluationContext, Error>

    public static func evaluate(
        _ node: LGCSyntaxNode,
        rootNode: LGCSyntaxNode,
        scopeContext: ScopeContext,
        unificationContext: UnificationContext,
        substitution: Unification.Substitution,
        context: EvaluationContext
        ) -> EvaluationResult {

//        Swift.print("Handle", node.nodeTypeDescription)

        func processChildren(result: Result<EvaluationContext, Error>) -> EvaluationResult {
            return node.subnodes.reduce(result, { result, child in
                switch result {
                case .failure:
                    return result
                case .success(let newContext):
                    return evaluate(
                        child,
                        rootNode: rootNode,
                        scopeContext: scopeContext,
                        unificationContext: unificationContext,
                        substitution: substitution,
                        context: newContext
                    )
                }
            })
        }

        var result: EvaluationResult

        // Pre
        switch node {
        case .statement(.branch(id: _, condition: let condition, block: _)):
            result = evaluate(
                condition.node,
                rootNode: rootNode,
                scopeContext: scopeContext,
                unificationContext: unificationContext,
                substitution: substitution,
                context: context
                ).flatMap({ context -> EvaluationResult in
                    if let value = context.evaluate(uuid: condition.uuid),
                        case .bool(let memory) = value.memory, memory == true,
                        value.type == .bool {

                        return processChildren(result: .success(context))
                    } else {
                        return .success(context)
                    }
                })
        default:
            result = processChildren(result: .success(context))
        }

        guard case .success(let context) = result else { return result }

        // Post
        switch node {
        case .literal(.boolean(id: _, value: let value)):
            context.add(uuid: node.uuid, EvaluationThunk(label: "Boolean Literal", { _ in LogicValue.bool(value) }))
        case .literal(.number(id: _, value: let value)):
            context.add(uuid: node.uuid, EvaluationThunk(label: "Number Literal", { _ in LogicValue.number(value) }))
        case .literal(.string(id: _, value: let value)):
            context.add(uuid: node.uuid, EvaluationThunk(label: "String Literal", { _ in LogicValue.string(value) }))
        case .literal(.color(id: _, value: let value)):
            context.add(uuid: node.uuid, EvaluationThunk(label: "Color Literal", { _ in LogicValue.color(value) }))
        case .literal(.array(id: _, value: let expressions)):
            guard let type = unificationContext.nodes[node.uuid] else {
                Swift.print("Failed to unify type of array")
                break
            }

            let resolvedType = Unification.substitute(substitution, in: type)

            let dependencies = expressions.filter { !$0.isPlaceholder }.map { $0.uuid }

            context.add(uuid: node.uuid, EvaluationThunk(label: "Array Literal", dependencies: dependencies, { values in
                return LogicValue(resolvedType, .array(values))
            }))
        case .expression(.literalExpression(id: _, literal: let literal)):
            context.add(uuid: node.uuid, EvaluationThunk(label: "Literal expression", dependencies: [literal.uuid], { values in
                return values[0]
            }))
        case .expression(.identifierExpression(id: _, identifier: let identifier)):
            guard let patternId = scopeContext.identifierToPattern[identifier.uuid] else {
//                Swift.print("Failed to find pattern for identifier expression")
                break
            }

            context.add(uuid: identifier.uuid, EvaluationThunk(label: "Identifier \(identifier.string)", dependencies: [patternId], { values in
                return values[0]
            }))
            context.add(uuid: node.uuid, EvaluationThunk(label: "Identifier expression \(identifier.string)", dependencies: [patternId], { values in
                return values[0]
            }))
        case .expression(.memberExpression):
            guard let patternId = scopeContext.identifierToPattern[node.uuid] else {
                Swift.print("Failed to find pattern for member expression")
                break
            }

            context.add(uuid: node.uuid, EvaluationThunk(label: "Member expression",  dependencies: [patternId], { values in
                return values[0]
            }))
        case .expression(.binaryExpression(left: let left, right: let right, op: let op, id: _)):
            Swift.print("binary expr", left, right, op)
        case .expression(.functionCallExpression(id: _, expression: let expression, arguments: let arguments)):

            // Determine type based on return value of constructor function
            guard let functionType = unificationContext.nodes[expression.uuid] else {
                Swift.print("Unknown type of functionCallExpression")
                break
            }

            let resolvedType = Unification.substitute(substitution, in: functionType)

            guard case .fun(_, let returnType) = resolvedType else {
                Swift.print("Invalid functionCallExpression type (only functions are valid)")
                break
            }

            let dependencies = [expression.uuid] + arguments.compactMap({
                switch $0 {
                case .argument(_, _, .identifierExpression(_, let identifier)) where identifier.isPlaceholder:
                    return nil
                case .argument(_, _, let expression):
                    return expression.uuid
                case .placeholder:
                    return nil
                }
            })

            context.add(uuid: node.uuid, EvaluationThunk(label: "functionCallExpression",  dependencies: dependencies, { values in
                let functionValue = values[0]
                let args = Array(values.dropFirst())

                if case .function(let f) = functionValue.memory {
                    switch f {
                    case .colorFromHSL:
                        func makeColor(componentValues: [LogicValue]) -> LogicValue {
                            let numbers: [CGFloat] = componentValues.map { componentValue in
                                guard case .number(let number) = componentValue.memory else { return 0 }
                                return number
                            }

                            let newSwiftColor = Color(hue: Float(numbers[0]), saturation: Float(numbers[1]), luminosity: Float(numbers[2]))

                            return LogicValue.color(newSwiftColor.cssString)
                        }

                        if args.count >= 3 {
                            return makeColor(componentValues: args)
                        } else {
                            break
                        }
                    case .colorSetHue:
                        func setHue(colorValue: LogicValue?, numberValue: LogicValue?) -> LogicValue {
                            let defaultColor = LogicValue.color("black")
                            guard let colorString = colorValue?.colorString else { return defaultColor }
                            guard case .number(let number)? = numberValue?.memory else { return defaultColor }

                            let originalSwiftColor = Color(cssString: colorString)
                            let components = originalSwiftColor.hsl
                            let newSwiftColor = Color(hue: Float(number), saturation: components.saturation, luminosity: components.luminosity)

                            return LogicValue.color(newSwiftColor.cssString)
                        }

                        if args.count >= 2 {
                            return setHue(colorValue: args[0], numberValue: args[1])
                        } else {
                            break
                        }
                    case .colorSetSaturation:
                        func setSaturation(colorValue: LogicValue?, numberValue: LogicValue?) -> LogicValue {
                            let defaultColor = LogicValue.color("black")
                            guard let colorString = colorValue?.colorString else { return defaultColor }
                            guard case .number(let number)? = numberValue?.memory else { return defaultColor }

                            let originalSwiftColor = Color(cssString: colorString)
                            let components = originalSwiftColor.hsl
                            let newSwiftColor = Color(hue: components.hue, saturation: Float(number), luminosity: components.luminosity)

                            return LogicValue.color(newSwiftColor.cssString)
                        }

                        if args.count >= 2 {
                            return setSaturation(colorValue: args[0], numberValue: args[1])
                        } else {
                            break
                        }
                    case .colorSetLightness:
                        func setLuminosity(colorValue: LogicValue?, numberValue: LogicValue?) -> LogicValue {
                            let defaultColor = LogicValue.color("black")
                            guard let colorString = colorValue?.colorString else { return defaultColor }
                            guard case .number(let number)? = numberValue?.memory else { return defaultColor }

                            let originalSwiftColor = Color(cssString: colorString)
                            let components = originalSwiftColor.hsl
                            let newSwiftColor = Color(hue: components.hue, saturation: components.saturation, luminosity: Float(number))

                            return LogicValue.color(newSwiftColor.cssString)
                        }

                        if args.count >= 2 {
                            return setLuminosity(colorValue: args[0], numberValue: args[1])
                        } else {
                            break
                        }
                    case .colorSaturate:
                        func saturate(colorValue: LogicValue?, numberValue: LogicValue?) -> LogicValue {
                            let defaultColor = LogicValue.color("black")
                            guard let colorString = colorValue?.colorString else { return defaultColor }
                            guard case .number(let number)? = numberValue?.memory else { return defaultColor }

                            guard let nsColor = NSColor.parse(css: colorString) else { return defaultColor }

                            let newColor = NSColor(hue: nsColor.hueComponent, saturation: nsColor.saturationComponent * number, brightness: nsColor.brightnessComponent, alpha: nsColor.alphaComponent)

                            return LogicValue.color(newColor.cssString)
                        }

                        if args.count >= 2 {
                            return saturate(colorValue: args[0], numberValue: args[1])
                        } else {
                            break
                        }
                    case .stringConcat:
                        func concat(a: LogicValue?, b: LogicValue?) -> LogicValue {
                            guard case .string(let a)? = a?.memory else { return .unit }
                            guard case .string(let b)? = b?.memory else { return .unit }
                            return .init(.string, .string(a + b))
                        }

                        //                    Swift.print(f, "Args", args)
                        return concat(a: args[0], b: args[1])
                    case .enumInit(let patternName):

                        //                    Swift.print("init enum", returnType, patternName)

                        let filtered = args.compactMap { $0 }

                        if filtered.count != args.count { break }

                        return LogicValue(returnType, .enum(caseName: patternName, associatedValues: filtered))
                    case .recordInit(let members):
                        let values: [(String, LogicValue?)] = members.reduce([]) { (result, item) in
                            let argument = arguments.first(where: { argument in
                                switch argument {
                                case .argument(_, label: .some(item.0), _):
                                    return true
                                case .argument, .placeholder:
                                    return false
                                }
                            })
                            let argumentValue: LogicValue? = argument.flatMap({ argument in
                                switch argument {
                                case .argument(_, _, .identifierExpression(_, let identifier)) where identifier.isPlaceholder:
                                    // In the case of a placeholder identifier, continue running the function as if no argument is passed
                                    return nil
                                case .argument(_, _, let expression):
                                    guard let dependencyIndex = dependencies.firstIndex(of: expression.uuid) else { return nil }
                                    return values[dependencyIndex]
                                case .placeholder:
                                    return nil
                                }
                            })
                            switch argumentValue {
                            case .some:
                                return result + [(item.0, argumentValue)]
                            case .none:
                                return result + [(item.0, item.1.1)]
                            }
                        }

                        return LogicValue(returnType, .record(values: KeyValueList(values)))
                    case .arrayAt:
                        func arrayAt(arrayValue: LogicValue?, numberValue: LogicValue?) -> LogicValue {
                            guard let array = arrayValue?.array else { return .unit }
                            guard case .number(let float)? = numberValue?.memory else { return .unit }
                            let number = Int(float)
                            if number < 0 || number > array.count - 1 { return .unit }
                            return array[number]
                        }

                        if args.count >= 2 {
                            let result = arrayAt(arrayValue: args[0], numberValue: args[1])
                            Swift.print("Access array at \(args[1]): \(result)")
                            return result
                        } else {
                            break
                        }
                    case .numberRange:
                        func numberRange(from startValue: LogicValue?, to endValue: LogicValue?, strideValue: LogicValue?) -> LogicValue {
                            guard case .number(let start)? = startValue?.memory,
                                case .number(let end)? = endValue?.memory
                                else { return .unit }

                            var step: CGFloat
                            if case .number(let value)? = strideValue?.memory {
                                step = value
                            } else {
                                step = 1
                            }

                            let range = stride(from: start, to: end, by: step).map { LogicValue.number($0) }
                            return LogicValue(.array(.number), .array(range))
                        }

                        if args.count >= 2 {
                            let result = numberRange(from: args[0], to: args[1], strideValue: args.count > 2 ? args[2] : nil)
                            Swift.print("Access array at \(args[1]): \(result)")
                            return result
                        } else {
                            break
                        }
                    }
                }

                return .unit
            }))
        case .declaration(.variable(_, let pattern, _, let initializer, _)):
            guard let initializer = initializer else { return .success(context) }

            context.add(uuid: pattern.uuid, EvaluationThunk(label: "Variable initializer for \(pattern.name)", dependencies: [initializer.uuid], { values in
                return values[0]
            }))
        case .declaration(.function(_, name: let pattern, returnType: _, genericParameters: _, parameters: _, block: _, _)):
            guard let type = unificationContext.patternTypes[pattern.uuid] else { break }

            let fullPath = rootNode.declarationPath(id: node.uuid)

            context.add(uuid: pattern.uuid, EvaluationThunk(label: "Function declaration for \(pattern.name)", { values in
                guard let f = LogicValue.Function(qualifiedName: fullPath) else { return .unit }
                return LogicValue(type, .function(f))
            }))
        case .declaration(.record(id: _, name: let functionName, genericParameters: _, declarations: let declarations, _)):
            guard let type = unificationContext.patternTypes[functionName.uuid] else {
                Swift.print("Unknown type of record \(functionName.name)")
                break
            }

            let resolvedType = Unification.substitute(substitution, in: type)

            var dependencies: [UUID] = []

            declarations.forEach { declaration in
                switch declaration {
                case .variable(id: _, name: _, annotation: _, initializer: .some(let initializer), _):
                    dependencies.append(initializer.uuid)
                default:
                    break
                }
            }

            context.add(uuid: functionName.uuid, EvaluationThunk(label: "Record declaration for \(functionName.name)", dependencies: dependencies, { values in
                var parameterTypes: KeyValueList<String, (Unification.T, LogicValue?)> = [:]

                var index: Int = 0

                declarations.forEach { declaration in
                    switch declaration {
                    case .variable(id: _, name: let pattern, annotation: _, initializer: let initializer, _):
                        guard let parameterType = unificationContext.patternTypes[pattern.uuid] else { break }

                        var initialValue: LogicValue?
                        if initializer != nil {
                            initialValue = values[index]
                            index += 1
                        }

                        parameterTypes.set((parameterType, initialValue), for: pattern.name)
                    default:
                        break
                    }
                }

                return LogicValue(resolvedType, .function(.recordInit(members: parameterTypes)))
            }))
        case .declaration(.enumeration(id: _, name: let functionName, genericParameters: _, cases: let enumCases, _)):
            guard let type = unificationContext.patternTypes[functionName.uuid] else { break }

            enumCases.forEach { enumCase in
                switch enumCase {
                case .placeholder:
                    break
                case .enumerationCase(_, name: let pattern, associatedValueTypes: _, _):
                    let resolvedConsType = Unification.substitute(substitution, in: type)

                    context.add(uuid: pattern.uuid, EvaluationThunk(label: "Enum case declaration for \(pattern.name)", { values in
                        return LogicValue(resolvedConsType, .function(.enumInit(caseName: pattern.name)))
                    }))
                }
            }
        default:
            break
        }

        return .success(context)
    }
}

extension LGCSyntaxNode {
//    public func ancestors(in rootNode: LGCSyntaxNode) -> [LGCSyntaxNode] {
//        return rootNode.pathTo(id: uuid)?.dropLast().reversed() ?? []
//    }
//
//    public func parent(in rootNode: LGCSyntaxNode) -> LGCSyntaxNode? {
//        return ancestors(in: rootNode).first
//    }

    public func declarationPath(id: UUID) -> [String] {
        guard let path = pathTo(id: id) else { return [] }

        let declarations: [LGCDeclaration] = path.compactMap { node in
            switch node {
            case .declaration(let declaration):
                return declaration
            default:
                return nil
            }
        }

        let patterns: [LGCPattern] = declarations.compactMap { declaration in
            switch declaration {
            case .enumeration(_, let pattern, _, _, _),
                 .namespace(_, let pattern, _),
                 .record(_, let pattern, _, _, _),
                 .variable(_, let pattern, _, _, _),
                 .function(_, let pattern, _, _, _, _, _):
                return pattern
            default:
                return nil
            }
        }

        return patterns.map { $0.name }
    }
}
