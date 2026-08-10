name = "mizchi/bitx_kv"

version = "0.46.2"

import {
  "mizchi/bit_core@0.46.2",
  "mizchi/bit_object@0.46.2",
  "mizchi/bit_repo@0.46.2",
  "mizchi/bit_io@0.46.2",
  "mizchi/bit_lib@0.46.2",
  "mizchi/bit_types@0.46.2",
  "mizchi/bit_vfs@0.46.2",
  "mizchi/bit_osfs@0.46.2",
  "moonbitlang/async@0.19.4",
  "moonbitlang/x@0.4.40",
  "mizchi/x@0.2.0",
}

readme = "src/README.md"

repository = "https://github.com/mizchi/bit-vcs"

license = "Apache-2.0"

keywords = [ "git", "kv", "sync" ]

description = "Git-backed KV store with CRDT sync (extension module for mizchi/bit)"

source = "src"

preferred_target = "native"
