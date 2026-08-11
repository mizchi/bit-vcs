name = "mizchi/bit_pack"

version = "0.46.3"

import {
  "mizchi/bit_core@0.46.3",
  "mizchi/bit_object@0.46.3",
  "mizchi/bit_repo@0.46.3",
  "mizchi/bit_types@0.46.3",
  "mizchi/tempfile@0.1.2",
  "mizchi/zlib@0.4.8",
  "moonbitlang/async@0.19.4",
  "moonbitlang/x@0.4.40",
}

repository = "https://github.com/mizchi/bit-vcs"

license = "Apache-2.0"

keywords = [ "git", "pack", "packfile", "index" ]

description = "Git packfile encoder/decoder + index (gix-pack equivalent)"

source = "src"

preferred_target = "native"
