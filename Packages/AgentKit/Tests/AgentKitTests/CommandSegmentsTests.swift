import Foundation
import Testing
@testable import AgentKit

@Suite struct CommandSegmentsTests {
    private func parse(_ command: String) -> CommandSegments.Parsed { CommandSegments.parse(command) }

    @Test func splitsOnEverySeparator() {
        #expect(parse("a && b || c; d | e & f").segments == ["a", "b", "c", "d", "e", "f"])
        #expect(parse("one\ntwo").segments == ["one", "two"])
        #expect(parse("  ls -la  ").segments == ["ls -la"])
        #expect(parse("").segments.isEmpty)
        #expect(parse(" ; ; ").segments.isEmpty)
    }

    @Test func separatorsInsideQuotesStayInTheSegment() {
        #expect(parse(#"echo "a && b" | wc"#).segments == [#"echo "a && b""#, "wc"])
        #expect(parse("echo 'a; b'").segments == ["echo 'a; b'"])
        #expect(parse(#"echo a\;b"#).segments == [#"echo a\;b"#], "an escaped separator is text")
    }

    @Test func substitutionsSubshellsAndHeredocsAreOpaque() {
        #expect(parse("echo $(rm -rf x)").isOpaque)
        #expect(parse("echo `rm -rf x`").isOpaque)
        #expect(parse(#"echo "$(date)""#).isOpaque, "a substitution works inside double quotes")
        #expect(parse("echo '$(date)'").isOpaque == false, "and does not inside single quotes")
        #expect(parse("(cd x && ls)").isOpaque)
        #expect(parse("diff <(ls a) <(ls b)").isOpaque)
        #expect(parse("cat <<EOF\nhi\nEOF").isOpaque)
        #expect(parse("echo 'unclosed").isOpaque, "an unterminated quote is not a command we understand")
        #expect(parse("ls -la | grep foo").isOpaque == false)
    }

    @Test func redirectionsToFilesAreFlagged() {
        #expect(parse("echo hi > out.txt").hasRedirection)
        #expect(parse("echo hi >> out.txt").hasRedirection)
        #expect(parse("echo hi &> out.txt").hasRedirection)
        #expect(parse("ls 2> err.txt").hasRedirection)
        #expect(parse("make >/dev/null").hasRedirection == false)
        #expect(parse("make > /dev/null 2>&1").hasRedirection == false)
        #expect(parse("make 2>&1 | tail").hasRedirection == false)
        #expect(parse("make 2>&1 | tail").segments == ["make 2>&1", "tail"], "2>&1 is not a background marker")
    }

    @Test func wordsDropQuotesAndHonorEscapes() {
        #expect(CommandSegments.words(#"git commit -m "a b" 'c d'"#) == ["git", "commit", "-m", "a b", "c d"])
        #expect(CommandSegments.words(#"echo a\ b"#) == ["echo", "a b"])
        #expect(CommandSegments.words(#"echo "" x"#) == ["echo", "", "x"], "an empty quoted word is still a word")
        #expect(CommandSegments.words("   ").isEmpty)
    }
}

@Suite struct SafeCommandsTests {
    private func safe(_ command: String, secrets: [GlobPattern] = []) -> Bool {
        SafeCommands.isSafe(command, secretPatterns: secrets)
    }

    @Test func plainReadersInTheProjectAreSafe() {
        for command in ["ls", "ls -la src", "pwd", "cat README.md", "head -n 20 src/A.java", "wc -l a.txt b.txt",
                        "rg TODO src", "grep -rn foo .", "which swift", "echo hello", "date", "basename a/b.c", "cd src", "diff a b"] {
            #expect(safe(command), "\(command) should be safe")
        }
    }

    @Test func pathsOutsideTheProjectAreNot() {
        #expect(!safe("cat /etc/passwd"))
        #expect(!safe("ls ~"))
        #expect(!safe("cat ../secrets.txt"))
        #expect(!safe("ls src/../.."))
        #expect(safe("cat a..b"), "dots inside a name are not a parent reference")
    }

    @Test func credentialFilesAreNot() {
        #expect(!safe("cat .env"))
        #expect(!safe("head id_rsa"))
        #expect(!safe("cat config/server.pem"))
        #expect(!safe("cat notes.secret", secrets: SecretFilePolicy.patterns(from: ["*.secret"])))
    }

    @Test func variablesAndPathQualifiedCommandsAreNot() {
        #expect(!safe("echo $HOME"))
        #expect(!safe("cat $FILE"))
        #expect(!safe("./script.sh"))
        #expect(!safe("/bin/ls"))
        #expect(!safe("FOO=1 ls"))
        #expect(!safe(""))
    }

    @Test func flagsThatRunOrWriteAreNot() {
        #expect(!safe("rg --pre ./hook foo"))
        #expect(!safe("find . -name x -exec rm {} ;"))
        #expect(!safe("find . -delete"))
        #expect(safe("find . -name '*.java' -type f"))
        #expect(!safe("find / -name x"))
    }

    @Test func gitReadsAreSafeAndGitWritesAreNot() {
        for command in ["git status", "git status -sb", "git diff", "git diff HEAD~1 -- src/A.java", "git log --oneline -5",
                        "git show HEAD", "git branch", "git branch -a", "git branch --show-current", "git remote -v",
                        "git blame src/A.java", "git ls-files"] {
            #expect(safe(command), "\(command) should be safe")
        }
        for command in ["git push", "git commit -m x", "git checkout main", "git reset --hard", "git branch feature", "git branch -D x",
                        "git remote add o u", "git -C /tmp status", "git diff --output=out.patch", "git show HEAD:.env", "git stash", "git"] {
            #expect(!safe(command), "\(command) should not be safe")
        }
    }

    @Test func otherCommandsAreNotOnTheList() {
        for command in ["rm file", "mv a b", "cp a b", "touch x", "mkdir d", "curl http://x", "swift build", "npm test", "sed -i s/a/b/ f", "sort -o f f"] {
            #expect(!safe(command), "\(command) should not be safe")
        }
    }
}
