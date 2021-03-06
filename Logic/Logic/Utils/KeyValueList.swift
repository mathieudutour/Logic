//
//  KeyValueList.swift
//  LogicDesigner
//
//  Created by Devin Abbott on 5/17/19.
//  Copyright © 2019 BitDisco, Inc. All rights reserved.
//

import Foundation

public struct KeyValueList<Key: Equatable, Value>: KeyValueCollection {
    public typealias Key = Key
    public typealias Value = Value
    public typealias Pair = (Key, Value)

    public init(_ pairs: [Pair] = []) {
        self.pairs = pairs
    }

    public var pairs: [Pair]

    public func value(for key: Key) -> Value? {
        return pairs.first(where: { $0.0 == key })?.1
    }

    public mutating func set(_ value: Value?, for key: Key) {
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            if let value = value {
                pairs[index] = (key, value)
            } else {
                pairs.remove(at: index)
            }
        } else if let value = value {
            pairs.append((key, value))
        }
    }
}

extension KeyValueList where Key: Hashable {
    public var dictionary: [Key: Value] {
        return pairs.reduce(into: [:], { (result, pair) in
            result[pair.0] = pair.1
        })
    }
}

extension KeyValueList: Equatable where Value: Equatable {
    public static func == (lhs: KeyValueList<Key, Value>, rhs: KeyValueList<Key, Value>) -> Bool {
        if lhs.pairs.count != rhs.pairs.count { return false }

        for index in 0..<lhs.pairs.count {
            if lhs.pairs[index].0 != rhs.pairs[index].0 || lhs.pairs[index].1 != rhs.pairs[index].1 {
                return false
            }
        }

        return true
    }
}

extension KeyValueList: CustomDebugStringConvertible {
    public var debugDescription: String {
        let contents = pairs.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        return "[\(contents)]"
    }
}

extension KeyValueList: Collection {
    public typealias Index = Int
    public typealias Element = Pair

    public var startIndex: Index { return pairs.startIndex }
    public var endIndex: Index { return pairs.endIndex }
    public subscript(index: Index) -> Element { return pairs[index] }
    public func index(after i: Index) -> Index { return pairs.index(after: i) }
}

extension KeyValueList: BidirectionalCollection {
    public func index(before i: Index) -> Index { return pairs.index(before: i) }
}

extension KeyValueList: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.pairs = elements
    }
}
