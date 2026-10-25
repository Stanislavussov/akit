import AKitFoundation

/// One importer at a time: a `FileLock` on `import.lock`. Hooks never take it.
public typealias ImportLock = FileLock
