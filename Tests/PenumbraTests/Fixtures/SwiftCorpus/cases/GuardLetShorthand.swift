struct User { var name = "" }
func f(user: User?) {
    guard let user else { return }
    user./*|*/
}
//! contains: name
