struct Vault { private var secret = 1; var open = 2 }
let v = Vault()
v./*|*/
//! contains: open
//! excludes: secret
//! gap: access-control
