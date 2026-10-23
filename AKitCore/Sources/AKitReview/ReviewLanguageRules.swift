import Foundation

/// Built-in review rules of a language (`docs/design/review.md`, R21): on when the diff has a
/// file of that language, written into `context/project-rules.md`. Each rule names its severity
/// and the safe path that makes it no finding. Only TS/JS with React for now.
public enum ReviewLanguageRules {
    public struct RuleSet: Sendable, Hashable {
        public var id: String
        public var title: String
        public var extensions: [String]
        public var text: String
    }

    public static let typeScriptReact = RuleSet(
        id: "ts-react", title: "TypeScript / JavaScript and React",
        extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"],
        text: """
        Check these in the changed lines. The compiler, ESLint and Prettier settle style and types: never comment on them.

        Async code:
        - A promise nobody awaits, returns or catches (a floating promise) loses its error: high when a user action or data \
        depends on it. Safe path: `await`, `return`, `.catch(…)`, or `void promise` with a comment saying why.
        - `async` callbacks in `forEach`, `map` without `Promise.all`, or an event handler: the caller doesn't wait for them. \
        High when the order or the error matters. Safe path: `for … of` with `await`, or `Promise.all` / `Promise.allSettled`.
        - A `catch` that swallows the error (empty, or only `console.log`) on a path the user relies on: medium; high when it \
        hides a failed save or payment. Safe path: rethrow, or show the user an error and report it.

        Types at the edges:
        - `any`, `as` casts or a non-null `!` on data from an API, storage, a URL or user input, where a wrong shape crashes or \
        corrupts state: medium; high on a main path. Safe path: a runtime check (a schema such as zod, a type guard) at the edge.

        Security in the browser:
        - HTML from data into the DOM: `dangerouslySetInnerHTML`, `innerHTML`, `outerHTML`, `insertAdjacentHTML`, \
        `document.write`, without sanitizing: critical when the data comes from a user or an API. Safe path: render as text, \
        or sanitize with a known sanitizer (DOMPurify).
        - A URL from data in `href`, `src`, `window.location` or `window.open` without a scheme check (`javascript:`): high. \
        Safe path: allow only `https:` (and the app's own paths).
        - Tokens or personal data in `localStorage`, `sessionStorage`, logs or analytics events: high. Safe path: an \
        `HttpOnly` cookie, or no copy at all.
        - `eval`, `new Function`, `setTimeout` with a string: high.

        React:
        - `useEffect`, `useMemo`, `useCallback` whose dependency list misses a value the body reads (a stale closure), or \
        holds a new object or function on each render (a loop of effects or requests): high when the user sees stale data or \
        the app sends requests in a loop. Safe path: complete dependencies, or a stable value (`useCallback`, `useRef`, a value \
        moved out of the component).
        - An effect that subscribes, starts a timer, opens a socket or adds a listener without a cleanup: medium; high when it \
        runs per render or per route. Safe path: return a cleanup function.
        - A request in an effect whose answer is set into state with no cancel or ignore flag: an older answer can win \
        (a race) or set state after unmount: medium; high when it shows another item's data. Safe path: `AbortController`, \
        an `ignore` flag in the cleanup, or the project's data-fetching library.
        - State changed in place (`state.items.push(…)`, `obj.x = …` then `setState(obj)`): React may not render: high. Safe \
        path: a new array or object.
        - A list rendered without a stable `key`, or with the index as `key` when items are added, removed or reordered: \
        medium (wrong rows keep their state). Safe path: an id from the data.
        - A hook called under a condition, in a loop or after an early return: high (React's rules of hooks).
        - Data derived from props or state copied into state and never synced: medium. Safe path: compute it while rendering.
        """)

    public static let all = [typeScriptReact]

    /// The rule sets the changed files call for, each once.
    public static func sets(for paths: [String]) -> [RuleSet] {
        let extensions = Set(paths.map { ($0 as NSString).pathExtension.lowercased() })
        return all.filter { !extensions.isDisjoint(with: $0.extensions) }
    }

    /// The `project-rules.md` part of the rule sets.
    static func text(_ sets: [RuleSet]) -> String {
        sets.map { "\n## Built-in rules: \($0.title)\n\n\($0.text)\n" }.joined()
    }
}
