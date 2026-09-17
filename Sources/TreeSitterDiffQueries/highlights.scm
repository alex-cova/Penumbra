(comment) @comment

[
  (addition)
  (new_file)
] @diff.plus

[
  (deletion)
  (old_file)
] @diff.minus

(change) @diff.delta

(commit) @constant

(location) @attribute

(command
  "diff" @function
  (argument) @variable.parameter)

(filename) @string.special.path

(special) @string.special

"\\" @punctuation.special

(mode) @number

; Upstream applies `(#set! priority 95)` here; Penumbra's query evaluator treats any
; unrecognized `#set!`/`#eq?`-style directive as a failed predicate and drops the whole
; match (see `TreeSitterTextPredicatesEvaluator`), so the directive is omitted rather than
; silently losing this capture.
[
  ".."
  "+"
  "++"
  "+++"
  "++++"
  ">"
  "-"
  "--"
  "---"
  "----"
  "<"
  "!"
] @punctuation.special

[
  (binary_change)
  (similarity)
  (dissimilarity)
  (file_change)
] @label

(index
  "index" @keyword)

(similarity
  (score) @number
  "%" @number)

(dissimilarity
  (score) @number
  "%" @number)

(binary_patch
  [
    "GIT"
    "binary"
    "patch"
  ] @label)

(binary_hunk
  [
    "literal"
    "delta"
  ] @keyword
  (size) @number)

forward: (binary_hunk
  (payload) @diff.plus)

reverse: (binary_hunk
  (payload) @diff.minus)
