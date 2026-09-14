import ImpactData

public func render(_ store: any Store) -> String { store.read() }
public func renderLive() -> String { render(LiveStore()) }
public func renderExtension() -> String { LiveStore().extensionOnly() }
