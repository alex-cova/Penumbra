enum Mode { case fast, slow }
func run(mode: Mode) {}
run(mode: ./*|*/)
//! contains: fast, slow
