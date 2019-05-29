//
//  Library.swift
//  Logic
//
//  Created by Devin Abbott on 5/29/19.
//  Copyright © 2019 BitDisco, Inc. All rights reserved.
//

import Foundation

public enum Library {
    private static var cache: [String: LGCSyntaxNode] = [:]

    public static func load(name: String) -> LGCSyntaxNode {
        if let cached = cache[name] {
            return cached
        }

        let bundle = BundleLocator.getBundle()

        guard let libraryUrl = bundle.url(forResource: "Prelude", withExtension: "logic"),
            let libraryScript = try? Data(contentsOf: libraryUrl),
            let decoded = try? JSONDecoder().decode(LGCSyntaxNode.self, from: libraryScript)
        else {
            fatalError("Failed to load library: \(name)")
        }

        cache[name] = decoded

        return decoded
    }
}
