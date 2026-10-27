struct User { var name: String }
func f(user: User?) {
    user?./*|*/
}
//! contains: name
