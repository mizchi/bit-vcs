///| Human-readable `git status` formatting

///|
/// Format status output similar to `git status`.
pub fn status_text(
  fs : &RepoFileSystem,
  root : String,
) -> String raise GitError {
  let git_dir = join_path(root, ".git")
  let sb = StringBuilder::new()
  let head = read_head_ref(fs, git_dir)
  match head {
    Branch(name) => sb.write_string("On branch " + name + "\n")
    Detached(id) => {
      let short = shorten_hex(id.to_hex(), 7)
      sb.write_string("HEAD detached at " + short + "\n")
    }
  }
  let head_commit = resolve_head_commit(fs, git_dir)
  if head_commit is None {
    sb.write_string("No commits yet\n")
  }
  let st = status(fs, root)
  let has_staged = st.staged_added.length() > 0 ||
    st.staged_modified.length() > 0 ||
    st.staged_deleted.length() > 0
  if has_staged {
    sb.write_string("\nChanges to be committed:\n")
    for path in st.staged_added {
      sb.write_string("  staged: " + path + "\n")
    }
    for path in st.staged_modified {
      sb.write_string("  staged: " + path + "\n")
    }
    for path in st.staged_deleted {
      sb.write_string("  staged: " + path + "\n")
    }
  }
  let has_unstaged = st.unstaged_modified.length() > 0 ||
    st.unstaged_deleted.length() > 0
  if has_unstaged {
    sb.write_string("\nChanges not staged for commit:\n")
    for path in st.unstaged_modified {
      sb.write_string("  modified: " + path + "\n")
    }
    for path in st.unstaged_deleted {
      sb.write_string("  deleted: " + path + "\n")
    }
  }
  if st.untracked.length() > 0 {
    sb.write_string("\nUntracked files:\n")
    for path in st.untracked {
      sb.write_string("  " + path + "\n")
    }
  }
  if not(has_staged) && not(has_unstaged) && st.untracked.length() == 0 {
    sb.write_string("\nnothing to commit, working tree clean\n")
  }
  sb.to_string()
}
