struct User { var email: String? }
func f(user: User) {
    user.email?./*|*/
}
//! contains: count, uppercased, hasPrefix
