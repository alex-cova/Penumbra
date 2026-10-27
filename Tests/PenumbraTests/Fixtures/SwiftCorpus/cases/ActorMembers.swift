actor Store { var value = 0; func bump() { value += 1 } }
func f(store: Store) async {
    await store./*|*/
}
//! contains: value, bump
