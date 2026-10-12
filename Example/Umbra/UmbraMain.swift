import Darwin
import Foundation

/// The program's entry point. Git runs `$GIT_ASKPASS` / `$SSH_ASKPASS` to ask for a password or a
/// passphrase, and Umbra is that program: when the environment says so, answer the prompt through
/// the running app (`IDEGitAskPassClient`) and exit, before any AppKit or SwiftUI state exists.
@main
enum UmbraMain {
    static func main() {
        if IDEGitAskPassClient.isAskPassInvocation() {
            let status = IDEGitAskPassClient.run(arguments: CommandLine.arguments) { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
            exit(status)
        }
        UmbraApp.main()
    }
}
