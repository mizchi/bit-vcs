///| Interactive rebase: todo types, parser, serializer, autosquash, engine

// ============================================================================
// Types
// ============================================================================

///|
pub enum TodoCommand {
  Pick
  Reword
  Edit
  Squash
  Fixup
  Drop
  Exec
  Break
  Label
  Reset
  Merge
} derive(Debug, Eq)

///|
pub impl Show for TodoCommand with fn output(self, logger) {
  match self {
    Pick => logger.write_string("Pick")
    Reword => logger.write_string("Reword")
    Edit => logger.write_string("Edit")
    Squash => logger.write_string("Squash")
    Fixup => logger.write_string("Fixup")
    Drop => logger.write_string("Drop")
    Exec => logger.write_string("Exec")
    Break => logger.write_string("Break")
    Label => logger.write_string("Label")
    Reset => logger.write_string("Reset")
    Merge => logger.write_string("Merge")
  }
}

///|
pub struct InteractiveTodoEntry {
  command : TodoCommand
  commit_hex : String
  subject : String
} derive(Debug, Eq)

///|
fn parse_todo_command(s : String) -> TodoCommand? {
  match s {
    "pick" | "p" => Some(TodoCommand::Pick)
    "reword" | "r" => Some(TodoCommand::Reword)
    "edit" | "e" => Some(TodoCommand::Edit)
    "squash" | "s" => Some(TodoCommand::Squash)
    "fixup" | "f" => Some(TodoCommand::Fixup)
    "drop" | "d" => Some(TodoCommand::Drop)
    "exec" | "x" => Some(TodoCommand::Exec)
    "break" | "b" => Some(TodoCommand::Break)
    "label" | "l" => Some(TodoCommand::Label)
    "reset" | "t" => Some(TodoCommand::Reset)
    "merge" | "m" => Some(TodoCommand::Merge)
    _ => None
  }
}

///|
fn todo_command_to_string(cmd : TodoCommand) -> String {
  match cmd {
    Pick => "pick"
    Reword => "reword"
    Edit => "edit"
    Squash => "squash"
    Fixup => "fixup"
    Drop => "drop"
    Exec => "exec"
    Break => "break"
    Label => "label"
    Reset => "reset"
    Merge => "merge"
  }
}

///|
/// Parse "merge" entry arguments: `-C <oid> <label> [# comment]` or `<label> [# comment]`
fn parse_merge_todo_entry(after : String) -> InteractiveTodoEntry {
  if after.has_prefix("-C ") || after.has_prefix("-c ") {
    // merge -C <oid> <label> [# comment]
    let rest = @string_utils.trim_string(
      String::unsafe_substring(after, start=3, end=after.length()),
    )
    let sp = rest.find(" ")
    match sp {
      Some(idx) => {
        let oid = String::unsafe_substring(rest, start=0, end=idx)
        let label_and_comment = @string_utils.trim_string(
          String::unsafe_substring(rest, start=idx + 1, end=rest.length()),
        )
        // Strip # comment from label
        let label = match label_and_comment.find(" #") {
          Some(ci) =>
            @string_utils.trim_string(
              String::unsafe_substring(label_and_comment, start=0, end=ci),
            )
          None => label_and_comment
        }
        { command: TodoCommand::Merge, commit_hex: oid, subject: label }
      }
      None =>
        // Just "merge -C <oid>" with no label — shouldn't happen but handle it
        { command: TodoCommand::Merge, commit_hex: rest, subject: "" }
    }
  } else {
    // merge <label> [# comment] — no -C flag, no original commit
    let label = match after.find(" #") {
      Some(ci) =>
        @string_utils.trim_string(
          String::unsafe_substring(after, start=0, end=ci),
        )
      None => after
    }
    { command: TodoCommand::Merge, commit_hex: "", subject: label }
  }
}

///|
pub fn parse_interactive_todo(text : String) -> Array[InteractiveTodoEntry] {
  let entries : Array[InteractiveTodoEntry] = []
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    let trimmed = @string_utils.trim_string(line)
    if trimmed.length() == 0 || trimmed.has_prefix("#") {
      continue
    }
    let first_space = trimmed.find(" ")
    let cmd_str = match first_space {
      Some(sp1) => String::unsafe_substring(trimmed, start=0, end=sp1)
      None => trimmed // No space: entire line is the command (e.g., "break")
    }
    let after_trimmed = match first_space {
      Some(sp1) =>
        @string_utils.trim_string(
          String::unsafe_substring(trimmed, start=sp1 + 1, end=trimmed.length()),
        )
      None => ""
    }
    let second_space = after_trimmed.find(" ")
    let (commit_hex, subject) = match second_space {
      Some(sp2) =>
        (
          String::unsafe_substring(after_trimmed, start=0, end=sp2),
          @string_utils.trim_string(
            String::unsafe_substring(
              after_trimmed,
              start=sp2 + 1,
              end=after_trimmed.length(),
            ),
          ),
        )
      None => (after_trimmed, "")
    }
    match parse_todo_command(cmd_str) {
      Some(TodoCommand::Exec) =>
        // exec: rest of line is the command, no commit_hex
        entries.push({
          command: TodoCommand::Exec,
          commit_hex: "",
          subject: after_trimmed,
        })
      Some(TodoCommand::Label) =>
        // label <name>: no commit_hex, subject is the label name
        entries.push({
          command: TodoCommand::Label,
          commit_hex: "",
          subject: after_trimmed,
        })
      Some(TodoCommand::Reset) =>
        // reset <name>: no commit_hex, subject is the label name
        entries.push({
          command: TodoCommand::Reset,
          commit_hex: "",
          subject: after_trimmed,
        })
      Some(TodoCommand::Merge) =>
        // merge -C <oid> <label> [# comment]
        // or merge <label> [# comment] (without -C)
        entries.push(parse_merge_todo_entry(after_trimmed))
      Some(TodoCommand::Break) =>
        // break: no arguments
        entries.push({
          command: TodoCommand::Break,
          commit_hex: "",
          subject: "",
        })
      Some(cmd) => entries.push({ command: cmd, commit_hex, subject })
      None => ()
    }
  }
  entries
}

///|
pub fn serialize_interactive_todo(
  entries : Array[InteractiveTodoEntry],
) -> String {
  let sb = StringBuilder::new()
  for entry in entries {
    match entry.command {
      Label | Reset => {
        // label <name> / reset <name>
        sb.write_string(todo_command_to_string(entry.command))
        sb.write_string(" ")
        sb.write_string(entry.subject)
        sb.write_string("\n")
      }
      Merge => {
        // merge [-C <oid>] <label>
        sb.write_string("merge")
        if entry.commit_hex.length() > 0 {
          sb.write_string(" -C ")
          sb.write_string(entry.commit_hex)
        }
        sb.write_string(" ")
        sb.write_string(entry.subject)
        sb.write_string("\n")
      }
      Break => sb.write_string("break\n")
      Exec => {
        sb.write_string("exec ")
        sb.write_string(entry.subject)
        sb.write_string("\n")
      }
      _ => {
        sb.write_string(todo_command_to_string(entry.command))
        sb.write_string(" ")
        sb.write_string(entry.commit_hex)
        sb.write_string(" ")
        sb.write_string(entry.subject)
        sb.write_string("\n")
      }
    }
  }
  sb.to_string()
}

///|
/// Reorder todo entries for autosquash: move fixup!/squash! commits after their targets.
pub fn autosquash_interactive_todo(
  entries : Array[InteractiveTodoEntry],
) -> Array[InteractiveTodoEntry] {
  let normal : Array[InteractiveTodoEntry] = []
  let fixups : Array[(Int, InteractiveTodoEntry)] = []
  for entry in entries {
    let (prefix, new_cmd) = if entry.subject.has_prefix("fixup! ") {
      (
        String::unsafe_substring(
          entry.subject,
          start=7,
          end=entry.subject.length(),
        ),
        TodoCommand::Fixup,
      )
    } else if entry.subject.has_prefix("squash! ") {
      (
        String::unsafe_substring(
          entry.subject,
          start=8,
          end=entry.subject.length(),
        ),
        TodoCommand::Squash,
      )
    } else {
      normal.push(entry)
      continue
    }
    let mut target_idx = -1
    for i, n in normal {
      if n.subject == prefix || n.subject.has_prefix(prefix) {
        target_idx = i
      }
    }
    if target_idx >= 0 {
      fixups.push(
        (
          target_idx,
          {
            command: new_cmd,
            commit_hex: entry.commit_hex,
            subject: entry.subject,
          },
        ),
      )
    } else {
      normal.push(entry)
    }
  }
  let inserts : Map[Int, Array[InteractiveTodoEntry]] = Map([])
  for item in fixups {
    let (idx, entry) = item
    match inserts.get(idx) {
      Some(arr) => arr.push(entry)
      None => inserts[idx] = [entry]
    }
  }
  let result : Array[InteractiveTodoEntry] = []
  for i, entry in normal {
    result.push(entry)
    match inserts.get(i) {
      Some(fixes) =>
        for fix in fixes {
          result.push(fix)
        }
      None => ()
    }
  }
  result
}

// ============================================================================
// Interactive Rebase State
// ============================================================================

///|
pub struct InteractiveRebaseState {
  onto : @bit.ObjectId
  orig_head : @bit.ObjectId
  head_name : String // branch name or "" for detached
  todo : Array[InteractiveTodoEntry]
  done : Array[InteractiveTodoEntry]
  amend : Bool // true when stopped for edit (next continue should amend)
  squash_msg : String // accumulated squash message
  update_refs : Map[String, String] // ref_path → old_commit_hex (refs to update)
  commit_map : Map[String, String] // old_commit_hex → new_commit_hex (rebase mapping)
  labels : Map[String, String] // label_name → commit_hex (for --rebase-merges)
}

///|
pub fn save_interactive_rebase_state(
  fs : &@bit.FileSystem,
  git_dir : String,
  state : InteractiveRebaseState,
) -> Unit raise @bit.GitError {
  let rebase_dir = join_path(git_dir, "rebase-merge")
  fs.mkdir_p(rebase_dir)
  // Mark as interactive rebase
  fs.write_string(join_path(rebase_dir, "interactive"), "")
  fs.write_string(join_path(rebase_dir, "onto"), state.onto.to_hex() + "\n")
  fs.write_string(
    join_path(rebase_dir, "orig-head"),
    state.orig_head.to_hex() + "\n",
  )
  fs.write_string(join_path(rebase_dir, "head-name"), state.head_name + "\n")
  // Write todo file
  let todo_text = serialize_interactive_todo(state.todo)
  fs.write_string(join_path(rebase_dir, "git-rebase-todo"), todo_text)
  // Write done file
  let done_text = serialize_interactive_todo(state.done)
  fs.write_string(join_path(rebase_dir, "done"), done_text)
  // Write amend marker
  if state.amend {
    fs.write_string(join_path(rebase_dir, "amend"), "")
  } else {
    fs.remove_file(join_path(rebase_dir, "amend")) catch {
      _ => ()
    }
  }
  // Write squash message if non-empty
  if state.squash_msg.length() > 0 {
    fs.write_string(join_path(rebase_dir, "message-squash"), state.squash_msg)
  } else {
    fs.remove_file(join_path(rebase_dir, "message-squash")) catch {
      _ => ()
    }
  }
  // Write labels state (for --rebase-merges)
  if state.labels.length() > 0 {
    let sb = StringBuilder::new()
    for name, hex in state.labels {
      sb.write_string(name)
      sb.write_string(" ")
      sb.write_string(hex)
      sb.write_string("\n")
    }
    fs.write_string(join_path(rebase_dir, "labels"), sb.to_string())
  } else {
    fs.remove_file(join_path(rebase_dir, "labels")) catch {
      _ => ()
    }
  }
  // Write update-refs state
  if state.update_refs.length() > 0 {
    let sb = StringBuilder::new()
    for ref_path, old_hex in state.update_refs {
      let new_hex = match state.commit_map.get(old_hex) {
        Some(h) => h
        None => ""
      }
      sb.write_string(old_hex)
      sb.write_string(" ")
      sb.write_string(new_hex)
      sb.write_string(" ")
      sb.write_string(ref_path)
      sb.write_string("\n")
    }
    fs.write_string(join_path(rebase_dir, "update-refs"), sb.to_string())
  } else {
    fs.remove_file(join_path(rebase_dir, "update-refs")) catch {
      _ => ()
    }
  }
}

///|
pub fn load_interactive_rebase_state(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> InteractiveRebaseState? raise @bit.GitError {
  let rebase_dir = join_path(git_dir, "rebase-merge")
  if !rfs.is_dir(rebase_dir) {
    return None
  }
  // Check for interactive marker
  if !rfs.is_file(join_path(rebase_dir, "interactive")) {
    return None
  }
  let onto_hex = read_file_trimmed(rfs, join_path(rebase_dir, "onto"))
  let orig_head_hex = read_file_trimmed(rfs, join_path(rebase_dir, "orig-head"))
  let head_name = read_file_trimmed(rfs, join_path(rebase_dir, "head-name"))
  let todo_text = interactive_read_file_or_empty(
    rfs,
    join_path(rebase_dir, "git-rebase-todo"),
  )
  let done_text = interactive_read_file_or_empty(
    rfs,
    join_path(rebase_dir, "done"),
  )
  let amend = rfs.is_file(join_path(rebase_dir, "amend"))
  let squash_msg = interactive_read_file_or_empty(
    rfs,
    join_path(rebase_dir, "message-squash"),
  )
  // Load labels state (for --rebase-merges)
  let labels : Map[String, String] = Map([])
  let labels_text = interactive_read_file_or_empty(
    rfs,
    join_path(rebase_dir, "labels"),
  )
  if labels_text.length() > 0 {
    for line_view in labels_text.split("\n") {
      let line = @string_utils.trim_string(line_view.to_owned())
      if line.length() == 0 {
        continue
      }
      let sp = line.find(" ")
      guard sp is Some(idx) else { continue }
      let name = String::unsafe_substring(line, start=0, end=idx)
      let hex = String::unsafe_substring(line, start=idx + 1, end=line.length())
      labels[name] = hex
    }
  }
  // Load update-refs state
  let update_refs : Map[String, String] = Map([])
  let commit_map : Map[String, String] = Map([])
  let update_refs_text = interactive_read_file_or_empty(
    rfs,
    join_path(rebase_dir, "update-refs"),
  )
  if update_refs_text.length() > 0 {
    for line_view in update_refs_text.split("\n") {
      let line = @string_utils.trim_string(line_view.to_owned())
      if line.length() == 0 {
        continue
      }
      // Format: old_hex new_hex ref_path
      let first_sp = line.find(" ")
      guard first_sp is Some(sp1) else { continue }
      let old_hex = String::unsafe_substring(line, start=0, end=sp1)
      let rest = String::unsafe_substring(
        line,
        start=sp1 + 1,
        end=line.length(),
      )
      let second_sp = rest.find(" ")
      guard second_sp is Some(sp2) else { continue }
      let new_hex = String::unsafe_substring(rest, start=0, end=sp2)
      let ref_path = String::unsafe_substring(
        rest,
        start=sp2 + 1,
        end=rest.length(),
      )
      update_refs[ref_path] = old_hex
      if new_hex.length() > 0 {
        commit_map[old_hex] = new_hex
      }
    }
  }
  Some({
    onto: @bit.ObjectId::from_hex(onto_hex),
    orig_head: @bit.ObjectId::from_hex(orig_head_hex),
    head_name,
    todo: parse_interactive_todo(todo_text),
    done: parse_interactive_todo(done_text),
    amend,
    squash_msg,
    update_refs,
    commit_map,
    labels,
  })
}

///|
fn interactive_read_file_or_empty(
  rfs : &@bit.RepoFileSystem,
  path : String,
) -> String {
  if !rfs.is_file(path) {
    return ""
  }
  @utf8.decode_lossy((rfs.read_file(path) catch { _ => Default::default() })[:])
}

// ============================================================================
// Interactive Rebase: generate todo text
// ============================================================================

///|
pub fn generate_interactive_todo_text(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  commits : Array[@bit.ObjectId],
) -> String raise @bit.GitError {
  let sb = StringBuilder::new()
  for commit in commits {
    let hex = commit.to_hex()
    let short = String::unsafe_substring(hex, start=0, end=7)
    let obj = db.get(rfs, commit)
    let subject = match obj {
      Some(o) => {
        let info = rebase_parse_commit_content(o.data)
        interactive_first_line(info.message)
      }
      None => "???"
    }
    sb.write_string("pick ")
    sb.write_string(short)
    sb.write_string(" ")
    sb.write_string(subject)
    sb.write_string("\n")
  }
  sb.write_string("\n")
  sb.write_string("# Rebase commands:\n")
  sb.write_string("# p, pick   <commit> = use commit\n")
  sb.write_string(
    "# r, reword <commit> = use commit, but edit the commit message\n",
  )
  sb.write_string("# e, edit   <commit> = use commit, but stop for amending\n")
  sb.write_string(
    "# s, squash <commit> = use commit, but meld into previous commit\n",
  )
  sb.write_string(
    "# f, fixup  <commit> = like squash, but discard this commit's log message\n",
  )
  sb.write_string("# d, drop   <commit> = remove commit\n")
  sb.write_string("#\n")
  sb.write_string("# If you remove a line here THAT COMMIT WILL BE LOST.\n")
  sb.write_string("#\n")
  sb.to_string()
}

///|
fn interactive_first_line(s : String) -> String {
  match s.find("\n") {
    Some(idx) =>
      @string_utils.trim_string(String::unsafe_substring(s, start=0, end=idx))
    None => @string_utils.trim_string(s)
  }
}

///|
/// Insert exec commands after each pick/reword/edit entry in a todo list.
/// git behavior: `--exec "cmd"` inserts `exec cmd` after every pick line.
pub fn insert_exec_after_picks(
  entries : Array[InteractiveTodoEntry],
  exec_cmds : Array[String],
) -> Array[InteractiveTodoEntry] {
  let result : Array[InteractiveTodoEntry] = []
  for entry in entries {
    result.push(entry)
    // Insert exec after pick, reword, edit (not after squash/fixup/drop/exec/break)
    match entry.command {
      Pick | Reword | Edit =>
        for cmd in exec_cmds {
          result.push({
            command: TodoCommand::Exec,
            commit_hex: "",
            subject: cmd,
          })
        }
      _ => ()
    }
  }
  result
}

///|
/// Extract comment lines from todo text (lines starting with #).
fn extract_todo_comments(text : String) -> String {
  let sb = StringBuilder::new()
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("#") {
      sb.write_string(line)
      sb.write_string("\n")
    }
  }
  sb.to_string()
}

// ============================================================================
// Interactive Rebase: DAG collection for --rebase-merges
// ============================================================================

///|
/// Collect all commits between upstream and head, including merge commits.
/// Returns commits in topological order (parents before children).
fn rebase_collect_dag(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  head : @bit.ObjectId,
  upstream : @bit.ObjectId,
) -> Array[@bit.ObjectId] raise @bit.GitError {
  // Find the merge base
  let merge_base = find_merge_base(db, fs, head, upstream)
  guard merge_base is Some(base) else {
    raise @bit.GitError::InvalidObject("No common ancestor found")
  }
  // BFS to collect all ancestors of base (stop set)
  let base_ancestors : Map[String, Bool] = Map([])
  base_ancestors[base.to_hex()] = true
  let bfs_queue : Array[@bit.ObjectId] = [base]
  let mut qi = 0
  while qi < bfs_queue.length() {
    let cur = bfs_queue[qi]
    qi += 1
    let obj = db.get(fs, cur)
    match obj {
      Some(o) => {
        let info = @bit.parse_commit(o.data)
        for p in info.parents {
          if !base_ancestors.contains(p.to_hex()) {
            base_ancestors[p.to_hex()] = true
            bfs_queue.push(p)
          }
        }
      }
      None => ()
    }
  }
  // BFS from head, collecting commits not in base_ancestors
  let visited : Map[String, Bool] = Map([])
  let result : Array[@bit.ObjectId] = []
  let queue : Array[@bit.ObjectId] = [head]
  visited[head.to_hex()] = true
  let mut idx = 0
  while idx < queue.length() {
    let cur = queue[idx]
    idx += 1
    let hex = cur.to_hex()
    if base_ancestors.contains(hex) {
      continue
    }
    result.push(cur)
    let obj = db.get(fs, cur)
    match obj {
      Some(o) => {
        let info = @bit.parse_commit(o.data)
        for p in info.parents {
          let ph = p.to_hex()
          if !visited.contains(ph) {
            visited[ph] = true
            queue.push(p)
          }
        }
      }
      None => ()
    }
  }
  // Reverse to get topological order (parents first)
  result.rev()
}

///|
/// Generate todo text for --rebase-merges mode.
/// Produces label/reset/merge commands to preserve merge topology.
fn generate_rebase_merges_todo_text(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  commits : Array[@bit.ObjectId],
  upstream : @bit.ObjectId,
) -> String raise @bit.GitError {
  let merge_base = find_merge_base(
    db,
    rfs,
    commits[commits.length() - 1],
    upstream,
  )
  let base_hex = match merge_base {
    Some(b) => b.to_hex()
    None => upstream.to_hex()
  }
  // Build set for quick lookup
  let commit_set : Map[String, Bool] = Map([])
  for c in commits {
    commit_set[c.to_hex()] = true
  }
  // Build children map and parent info
  let parents_map : Map[String, Array[@bit.ObjectId]] = Map([])
  let is_merge : Map[String, Bool] = Map([])
  for c in commits {
    let obj = db.get(rfs, c)
    match obj {
      Some(o) => {
        let info = @bit.parse_commit(o.data)
        parents_map[c.to_hex()] = info.parents
        if info.parents.length() > 1 {
          is_merge[c.to_hex()] = true
        }
      }
      None => ()
    }
  }
  // Find which commits are referenced as second+ parent of merges (need labels)
  let needs_label : Map[String, String] = Map([]) // commit_hex → label_name
  let mut label_counter = 0
  for c in commits {
    let hex = c.to_hex()
    if !is_merge.get(hex).unwrap_or(false) {
      continue
    }
    let ps = parents_map.get(hex).unwrap_or([])
    // Second and subsequent parents need labels
    for i = 1; i < ps.length(); i = i + 1 {
      let ph = ps[i].to_hex()
      if commit_set.contains(ph) && !needs_label.contains(ph) {
        // Try to derive a label name from commit subject
        let label = "branch-\{label_counter}"
        label_counter += 1
        needs_label[ph] = label
      } else if !commit_set.contains(ph) && !needs_label.contains(ph) {
        // Parent is outside the rebase range — label it as external
        let label = "branch-\{label_counter}"
        label_counter += 1
        needs_label[ph] = label
      }
    }
  }
  // Walk first-parent chains and build branches
  // A "branch" is a sequence of commits along first-parent that ends at
  // a labeled commit or at the base.
  let sb = StringBuilder::new()
  sb.write_string("label onto\n\n")
  // Emit label commands for external parents (outside the rebase range).
  // These are merge parents not in commit_set that need labels so that
  // merge commands can reference them.
  for ch, label in needs_label {
    if !commit_set.contains(ch) {
      sb.write_string("reset \{ch}\n")
      sb.write_string("label \{label}\n\n")
    }
  }
  // Group commits into branches by tracing first-parent chains backward
  // from each commit that needs a label (these are side branch tips)
  // Strategy: process commits in topological order (parents first).
  // Track which "branch" each commit belongs to.
  // First, identify branch tips: commits that are second+ parents of merges
  // and the final commit (HEAD)
  let head_hex = commits[commits.length() - 1].to_hex()
  // For each labeled commit, trace its first-parent chain until we hit
  // a commit that's already assigned or is outside the range
  // Process labeled commits + HEAD
  let branch_tips : Array[(String, String)] = [] // (commit_hex, label_name)
  for ch, label in needs_label {
    if commit_set.contains(ch) {
      branch_tips.push((ch, label))
    }
  }
  // HEAD is always the main branch
  branch_tips.push((head_hex, ""))
  // Sort so that earlier commits in the topo order come first
  let commit_order : Map[String, Int] = Map([])
  for i, c in commits {
    commit_order[c.to_hex()] = i
  }
  // Process each branch: trace first-parent chain, collect picks
  let branch_entries : Array[(String, Array[InteractiveTodoEntry])] = []
  let processed : Map[String, Bool] = Map([])
  // Process branches in reverse topological order of their tips
  // so that dependencies (labels) are defined before they're needed
  let sorted_tips = branch_tips.copy()
  sorted_tips.sort_by(fn(a, b) {
    let oa = commit_order.get(a.0).unwrap_or(0)
    let ob = commit_order.get(b.0).unwrap_or(0)
    oa - ob
  })
  for tip in sorted_tips {
    let (tip_hex, label) = tip
    if processed.contains(tip_hex) {
      continue
    }
    // Trace first-parent chain from tip backward
    let chain : Array[@bit.ObjectId] = []
    let mut cur_hex = tip_hex
    while true {
      if !commit_set.contains(cur_hex) || processed.contains(cur_hex) {
        break
      }
      chain.push(@bit.ObjectId::from_hex(cur_hex))
      processed[cur_hex] = true
      let ps = parents_map.get(cur_hex).unwrap_or([])
      if ps.length() == 0 {
        break
      }
      cur_hex = ps[0].to_hex()
    }
    chain.rev_in_place()
    // Determine what to reset to
    let reset_target = if chain.length() > 0 {
      let first = chain[0]
      let ps = parents_map.get(first.to_hex()).unwrap_or([])
      if ps.length() > 0 {
        let p0hex = ps[0].to_hex()
        if p0hex == base_hex || !commit_set.contains(p0hex) {
          "onto"
        } else {
          // Find which label this parent has
          match needs_label.get(p0hex) {
            Some(l) => l
            None => "onto"
          }
        }
      } else {
        "onto"
      }
    } else {
      "onto"
    }
    // Build entries for this branch
    let entries : Array[InteractiveTodoEntry] = []
    entries.push({
      command: TodoCommand::Reset,
      commit_hex: "",
      subject: reset_target,
    })
    for c in chain {
      let ch = c.to_hex()
      if is_merge.get(ch).unwrap_or(false) {
        // This is a merge commit
        let ps = parents_map.get(ch).unwrap_or([])
        // The second parent should have a label
        if ps.length() > 1 {
          let p2hex = ps[1].to_hex()
          let merge_label = needs_label.get(p2hex).unwrap_or("unknown")
          let short = String::unsafe_substring(ch, start=0, end=7)
          let subject = match db.get(rfs, c) {
            Some(o) => {
              let info = rebase_parse_commit_content(o.data)
              interactive_first_line(info.message)
            }
            None => "???"
          }
          ignore(subject)
          entries.push({
            command: TodoCommand::Merge,
            commit_hex: ch,
            subject: merge_label,
          })
          ignore(short)
        }
      } else {
        let short = String::unsafe_substring(ch, start=0, end=7)
        let subject = match db.get(rfs, c) {
          Some(o) => {
            let info = rebase_parse_commit_content(o.data)
            interactive_first_line(info.message)
          }
          None => "???"
        }
        entries.push({ command: TodoCommand::Pick, commit_hex: short, subject })
      }
    }
    // Add label at end if this branch is labeled
    if label.length() > 0 {
      entries.push({
        command: TodoCommand::Label,
        commit_hex: "",
        subject: label,
      })
    }
    branch_entries.push((label, entries))
  }
  // Output branches: side branches first, then main branch (empty label)
  for item in branch_entries {
    let (label, entries) = item
    if label.length() == 0 {
      continue
    }
    sb.write_string("# Branch \{label}\n")
    for entry in entries {
      sb.write_string(serialize_single_todo_entry(entry))
    }
    sb.write_string("\n")
  }
  // Main branch last
  for item in branch_entries {
    let (label, entries) = item
    if label.length() > 0 {
      continue
    }
    for entry in entries {
      sb.write_string(serialize_single_todo_entry(entry))
    }
    sb.write_string("\n")
  }
  sb.write_string("# Rebase commands:\n")
  sb.write_string("# p, pick   <commit> = use commit\n")
  sb.write_string("# l, label  <name>  = label current HEAD with a name\n")
  sb.write_string("# t, reset  <name>  = reset HEAD to a label\n")
  sb.write_string(
    "# m, merge  [-C <commit>] <label> = create a merge using the original merge commit's message\n",
  )
  sb.write_string("#\n")
  sb.to_string()
}

///|
fn serialize_single_todo_entry(entry : InteractiveTodoEntry) -> String {
  let sb = StringBuilder::new()
  match entry.command {
    Label | Reset => {
      sb.write_string(todo_command_to_string(entry.command))
      sb.write_string(" ")
      sb.write_string(entry.subject)
      sb.write_string("\n")
    }
    Merge => {
      sb.write_string("merge")
      if entry.commit_hex.length() > 0 {
        sb.write_string(" -C ")
        sb.write_string(entry.commit_hex)
      }
      sb.write_string(" ")
      sb.write_string(entry.subject)
      sb.write_string("\n")
    }
    Break => sb.write_string("break\n")
    Exec => {
      sb.write_string("exec ")
      sb.write_string(entry.subject)
      sb.write_string("\n")
    }
    _ => {
      sb.write_string(todo_command_to_string(entry.command))
      sb.write_string(" ")
      sb.write_string(entry.commit_hex)
      sb.write_string(" ")
      sb.write_string(entry.subject)
      sb.write_string("\n")
    }
  }
  sb.to_string()
}

// ============================================================================
// Interactive Rebase: start
// ============================================================================

///|
/// Start an interactive rebase. The sequence_editor callback is invoked with
/// the generated todo text and should return `Some(edited_text)` to proceed
/// or `None` to abort.
pub async fn interactive_rebase_start(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  upstream : @bit.ObjectId,
  onto : @bit.ObjectId,
  sequence_editor : async (String) -> String?,
  message_editor : async (String) -> String?,
  autosquash? : Bool = false,
  exec_runner? : (async (String) -> Int)? = None,
  exec_cmds? : Array[String] = [],
  update_refs? : Bool = false,
  root_mode? : Bool = false,
  rebase_merges? : Bool = false,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  if is_rebase_in_progress(rfs, git_dir) {
    raise @bit.GitError::InvalidObject(
      "A rebase is already in progress. Use --continue, --abort, or --skip.",
    )
  }
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(h) else {
    raise @bit.GitError::InvalidObject("Cannot resolve HEAD")
  }
  let db = ObjectDb::load(rfs, git_dir)
  // Collect commits to rebase
  let commits = if root_mode {
    rebase_collect_chain_to_root(db, rfs, h)
  } else if rebase_merges {
    rebase_collect_dag(db, rfs, h, upstream)
  } else {
    rebase_collect_chain(db, rfs, h, upstream)
  }
  if commits.length() == 0 {
    return {
      status: IRBComplete,
      commit_id: Some(h),
      message: "",
      exit_code: 0,
    }
  }
  // Save head name before detaching
  let head_name = match read_head_ref(rfs, git_dir) {
    HeadRef::Branch(name) => "refs/heads/" + name
    HeadRef::Detached(_) => ""
  }
  // Generate todo text
  let todo_text = if rebase_merges {
    generate_rebase_merges_todo_text(db, rfs, commits, upstream)
  } else {
    generate_interactive_todo_text(db, rfs, commits)
  }
  // Pre-process: autosquash and exec insertion before editor
  let mut pre_entries = parse_interactive_todo(todo_text)
  if autosquash {
    pre_entries = autosquash_interactive_todo(pre_entries)
  }
  // Insert exec commands after each pick/reword/edit entry
  let pre_entries_final = if exec_cmds.length() > 0 {
    insert_exec_after_picks(pre_entries, exec_cmds)
  } else {
    pre_entries
  }
  // Reconstruct todo text with comments for the editor
  let todo_for_editor = serialize_interactive_todo(pre_entries_final) +
    extract_todo_comments(todo_text)
  // Call sequence editor
  let edited = sequence_editor(todo_for_editor) catch { _ => None }
  guard edited is Some(edited_text) else {
    return {
      status: IRBAborted,
      commit_id: None,
      message: "rebase aborted",
      exit_code: 1,
    }
  }
  // Parse edited todo
  let entries = parse_interactive_todo(edited_text)
  if entries.length() == 0 {
    return {
      status: IRBAborted,
      commit_id: None,
      message: "error: nothing to do",
      exit_code: 1,
    }
  }
  // Resolve short hex to full hex in entries
  let resolved_entries = interactive_resolve_entries(rfs, git_dir, entries)
  // Collect refs to update if --update-refs is enabled
  let update_refs_map : Map[String, String] = Map([])
  if update_refs {
    let commit_set : Map[String, Bool] = Map([])
    for entry in resolved_entries {
      if entry.commit_hex.length() > 0 {
        commit_set[entry.commit_hex] = true
      }
    }
    let all_refs = list_refs_with_ids(rfs, git_dir, Some("refs/heads/"))
    for ref_path, ref_id in all_refs {
      let hex = ref_id.to_hex()
      // Skip the branch being rebased (it's handled by head_name restoration)
      if ref_path == head_name {
        continue
      }
      if commit_set.contains(hex) {
        update_refs_map[ref_path] = hex
      }
    }
  }
  // Detach HEAD at onto (for --root mode, point HEAD to unborn branch)
  if root_mode {
    // Point HEAD to a non-existent branch to simulate orphan state.
    // resolve_head_commit will return None, which interactive_cherry_pick handles.
    let head_path = join_path(git_dir, "HEAD")
    fs.write_string(head_path, "ref: refs/heads/_bit_rebase_orphan_\n")
    // Ensure the ref does not exist
    fs.remove_file(join_path(git_dir, "refs/heads/_bit_rebase_orphan_")) catch {
      _ => ()
    }
  } else {
    ignore(checkout(fs, rfs, root, onto.to_hex(), detach=true))
  }
  // Save state
  let state : InteractiveRebaseState = {
    onto,
    orig_head: h,
    head_name,
    todo: resolved_entries,
    done: [],
    amend: false,
    squash_msg: "",
    update_refs: update_refs_map,
    commit_map: Map([]),
    labels: Map([]),
  }
  save_interactive_rebase_state(fs, git_dir, state)
  // Execute the todo
  execute_interactive_todo(fs, rfs, root, state, message_editor, exec_runner~)
}

///|
fn interactive_resolve_entries(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[InteractiveTodoEntry],
) -> Array[InteractiveTodoEntry] raise @bit.GitError {
  let result : Array[InteractiveTodoEntry] = []
  for entry in entries {
    // exec, break, label, reset don't have commit references to resolve
    if entry.command == TodoCommand::Exec ||
      entry.command == TodoCommand::Break ||
      entry.command == TodoCommand::Label ||
      entry.command == TodoCommand::Reset {
      result.push(entry)
      continue
    }
    // merge without -C (empty commit_hex) doesn't need resolution
    if entry.command == TodoCommand::Merge && entry.commit_hex.length() == 0 {
      result.push(entry)
      continue
    }
    let hex = entry.commit_hex
    // Try to resolve short hex to full hex via rev_parse
    let resolved = if hex.length() < 40 {
      let id = rev_parse(rfs, git_dir, hex)
      guard id is Some(resolved_id) else {
        raise @bit.GitError::InvalidObject("Cannot resolve commit: " + hex)
      }
      resolved_id.to_hex()
    } else {
      hex
    }
    result.push({
      command: entry.command,
      commit_hex: resolved,
      subject: entry.subject,
    })
  }
  result
}

// ============================================================================
// Interactive Rebase: result type
// ============================================================================

///|
pub enum InteractiveRebaseStatus {
  IRBComplete
  IRBConflict
  IRBStopped // stopped for edit
  IRBAborted
}

///|
pub struct InteractiveRebaseResult {
  status : InteractiveRebaseStatus
  commit_id : @bit.ObjectId?
  message : String
  exit_code : Int
}

///|
/// Record old→new commit mapping for update-refs tracking.
fn interactive_record_commit_mapping(
  state : InteractiveRebaseState,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  old_hex : String,
) -> Unit {
  if state.update_refs.length() == 0 {
    return
  }
  let head = resolve_head_commit(rfs, git_dir) catch { _ => return () }
  guard head is Some(new_id) else { return }
  state.commit_map[old_hex] = new_id.to_hex()
}

// ============================================================================
// Interactive Rebase: execute todo loop
// ============================================================================

///|
pub async fn execute_interactive_todo(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  state : InteractiveRebaseState,
  message_editor : async (String) -> String?,
  exec_runner? : (async (String) -> Int)? = None,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(rfs, git_dir)
  if state.todo.length() == 0 {
    // All done
    return interactive_rebase_finish(fs, rfs, root, state)
  }
  let entry = state.todo[0]
  match entry.command {
    Pick => {
      let commit_id = @bit.ObjectId::from_hex(entry.commit_hex)
      let result = interactive_cherry_pick(fs, rfs, root, db, commit_id)
      match result.status {
        IRBConflict => {
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          return result
        }
        _ => {
          interactive_record_commit_mapping(
            state,
            rfs,
            git_dir,
            entry.commit_hex,
          )
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          execute_interactive_todo(
            fs,
            rfs,
            root,
            new_state,
            message_editor,
            exec_runner~,
          )
        }
      }
    }
    Reword => {
      let commit_id = @bit.ObjectId::from_hex(entry.commit_hex)
      let result = interactive_cherry_pick(fs, rfs, root, db, commit_id)
      match result.status {
        IRBConflict => {
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          return result
        }
        _ => {
          // Get original message and let editor modify it
          let info = rebase_parse_commit_full(db, rfs, commit_id)
          let edited_msg = message_editor(info.message) catch { _ => None }
          let msg = match edited_msg {
            Some(m) => m
            None => info.message
          }
          // Amend HEAD commit with new message
          interactive_amend_head_message(fs, rfs, root, db, msg)
          interactive_record_commit_mapping(
            state,
            rfs,
            git_dir,
            entry.commit_hex,
          )
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          execute_interactive_todo(
            fs,
            rfs,
            root,
            new_state,
            message_editor,
            exec_runner~,
          )
        }
      }
    }
    Edit => {
      let commit_id = @bit.ObjectId::from_hex(entry.commit_hex)
      let result = interactive_cherry_pick(fs, rfs, root, db, commit_id)
      match result.status {
        IRBConflict => {
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          return result
        }
        _ => {
          interactive_record_commit_mapping(
            state,
            rfs,
            git_dir,
            entry.commit_hex,
          )
          // Stop for user editing
          let new_state : InteractiveRebaseState = {
            ..interactive_move_to_done(state),
            amend: true,
          }
          save_interactive_rebase_state(fs, git_dir, new_state)
          let head = resolve_head_commit(rfs, git_dir)
          {
            status: IRBStopped,
            commit_id: head,
            message: "Stopped at " +
            String::unsafe_substring(
              entry.commit_hex,
              start=0,
              end=if entry.commit_hex.length() > 7 {
                7
              } else {
                entry.commit_hex.length()
              },
            ) +
            "... " +
            entry.subject,
            exit_code: 0,
          }
        }
      }
    }
    Squash => {
      let commit_id = @bit.ObjectId::from_hex(entry.commit_hex)
      let result = interactive_squash_into_head(
        fs,
        rfs,
        root,
        db,
        commit_id,
        state.squash_msg,
        false,
        message_editor,
      )
      match result.status {
        IRBConflict => {
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          return result
        }
        _ => {
          interactive_record_commit_mapping(
            state,
            rfs,
            git_dir,
            entry.commit_hex,
          )
          let new_state : InteractiveRebaseState = {
            ..interactive_move_to_done(state),
            squash_msg: result.message,
          }
          save_interactive_rebase_state(fs, git_dir, new_state)
          execute_interactive_todo(
            fs,
            rfs,
            root,
            new_state,
            message_editor,
            exec_runner~,
          )
        }
      }
    }
    Fixup => {
      let commit_id = @bit.ObjectId::from_hex(entry.commit_hex)
      let result = interactive_squash_into_head(
        fs,
        rfs,
        root,
        db,
        commit_id,
        state.squash_msg,
        true,
        message_editor,
      )
      match result.status {
        IRBConflict => {
          let new_state = interactive_move_to_done(state)
          save_interactive_rebase_state(fs, git_dir, new_state)
          return result
        }
        _ => {
          interactive_record_commit_mapping(
            state,
            rfs,
            git_dir,
            entry.commit_hex,
          )
          let new_state : InteractiveRebaseState = {
            ..interactive_move_to_done(state),
            squash_msg: result.message,
          }
          save_interactive_rebase_state(fs, git_dir, new_state)
          execute_interactive_todo(
            fs,
            rfs,
            root,
            new_state,
            message_editor,
            exec_runner~,
          )
        }
      }
    }
    Drop => {
      // Simply skip this commit
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      execute_interactive_todo(
        fs,
        rfs,
        root,
        new_state,
        message_editor,
        exec_runner~,
      )
    }
    Exec => {
      let cmd = entry.subject
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      let code = match exec_runner {
        Some(runner) => runner(cmd) catch { _ => 1 }
        None => 0 // No runner: skip exec commands silently
      }
      if code != 0 {
        // exec failed — stop and let user fix
        {
          status: IRBStopped,
          commit_id: resolve_head_commit(rfs, git_dir),
          message: "Execution failed: \{cmd} (exit code \{code})\nYou can fix the problem, and then run \"git rebase --continue\".",
          exit_code: code,
        }
      } else {
        // Check if exec left the tree dirty (unstaged or staged changes)
        let worktree_diffs = diff_worktree(rfs, root)
        let index_diffs = diff_index(rfs, root)
        if worktree_diffs.length() > 0 || index_diffs.length() > 0 {
          {
            status: IRBStopped,
            commit_id: resolve_head_commit(rfs, git_dir),
            message: "You have unstaged changes in your working tree.\nPlease commit or stash them.",
            exit_code: 1,
          }
        } else {
          execute_interactive_todo(
            fs,
            rfs,
            root,
            new_state,
            message_editor,
            exec_runner~,
          )
        }
      }
    }
    Break => {
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      {
        status: IRBStopped,
        commit_id: resolve_head_commit(rfs, git_dir),
        message: "Stopped at break point.\nYou can run \"git rebase --continue\" to resume.",
        exit_code: 0,
      }
    }
    Label => {
      // Record current HEAD as a label
      let head = resolve_head_commit(rfs, git_dir)
      guard head is Some(head_id) else {
        raise @bit.GitError::InvalidObject("No HEAD for label command")
      }
      state.labels[entry.subject] = head_id.to_hex()
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      execute_interactive_todo(
        fs,
        rfs,
        root,
        new_state,
        message_editor,
        exec_runner~,
      )
    }
    Reset => {
      // Reset HEAD to a labeled commit or a commit hash
      let label_name = entry.subject
      let hex = match state.labels.get(label_name) {
        Some(h) => h
        None =>
          // If the label is a full hex commit id, use it directly
          if label_name.length() == 40 || label_name.length() == 64 {
            label_name
          } else {
            // Try resolving as a rev-parse reference
            let resolved = rev_parse(rfs, git_dir, label_name)
            match resolved {
              Some(id) => id.to_hex()
              None =>
                raise @bit.GitError::InvalidObject(
                  "Unknown label: \{label_name}",
                )
            }
          }
      }
      ignore(checkout(fs, rfs, root, hex, detach=true))
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      execute_interactive_todo(
        fs,
        rfs,
        root,
        new_state,
        message_editor,
        exec_runner~,
      )
    }
    Merge => {
      // Create a merge commit combining current HEAD with the labeled commit
      let label_name = entry.subject
      let label_hex = match state.labels.get(label_name) {
        Some(h) => h
        None =>
          raise @bit.GitError::InvalidObject(
            "Unknown label for merge: \{label_name}",
          )
      }
      let label_id = @bit.ObjectId::from_hex(label_hex)
      // Get the merge message from the original commit (if -C was used)
      let merge_message = if entry.commit_hex.length() > 0 {
        let orig_id = @bit.ObjectId::from_hex(entry.commit_hex)
        let info = rebase_parse_commit_full(db, rfs, orig_id)
        info.message
      } else {
        "Merge branch '\{label_name}'"
      }
      let head = resolve_head_commit(rfs, git_dir)
      guard head is Some(head_id) else {
        raise @bit.GitError::InvalidObject("No HEAD for merge command")
      }
      // Perform three-way merge: find merge base between HEAD and label
      let base = find_merge_base(db, rfs, head_id, label_id)
      let base_files : Map[String, TreeFileEntry] = match base {
        Some(bid) => collect_tree_files_from_commit(db, rfs, bid)
        None => Map([])
      }
      let ours_files = collect_tree_files_from_commit(db, rfs, head_id)
      let theirs_files = collect_tree_files_from_commit(db, rfs, label_id)
      let file_result = merge_files(
        base_files, ours_files, theirs_files, db, rfs,
      )
      let merged = file_result.merged
      let conflicts = file_result.conflicts
      // Handle content merges
      for candidate in file_result.needs_content_merge {
        let base_content = match candidate.base_id {
          Some(id) => merge_get_blob_text(db, rfs, id)
          None => ""
        }
        let ours_content = merge_get_blob_text(db, rfs, candidate.ours_id)
        let theirs_content = merge_get_blob_text(db, rfs, candidate.theirs_id)
        let ours_data = merge_get_blob_data(db, rfs, candidate.ours_id)
        let theirs_data = merge_get_blob_data(db, rfs, candidate.theirs_id)
        if @diff3.is_binary_content(ours_data) ||
          @diff3.is_binary_content(theirs_data) {
          conflicts.push(candidate.path)
          continue
        }
        let result = @diff3.content_merge(
          base_content,
          ours_content,
          theirs_content,
          @diff3.ContentMergeOptions::default().with_labels(
            ours="HEAD",
            base="",
            theirs=label_name,
          ),
        )
        if result.has_conflicts {
          let full_path = join_path(root, candidate.path)
          let dir = rebase_parent_dir(full_path)
          fs.mkdir_p(dir)
          fs.write_string(full_path, result.content)
          conflicts.push(candidate.path)
        } else {
          let content_bytes = @utf8.encode(result.content)
          let (blob_id, compressed) = @bit.create_blob(content_bytes)
          write_object_bytes(fs, git_dir, blob_id, compressed)
          merged[candidate.path] = { id: blob_id, mode: candidate.mode }
        }
      }
      if conflicts.length() > 0 {
        // Write partial worktree, save stopped-sha for the merge commit
        write_worktree_from_files(
          db,
          fs,
          rfs,
          root,
          git_dir,
          merged,
          remove_missing=true,
        )
        let entries = tree_files_to_index(db, rfs, merged)
        write_index_entries(fs, git_dir, entries)
        // Save the merge state so continue can finish it
        fs.write_string(
          join_path(git_dir, "rebase-merge/stopped-sha"),
          entry.commit_hex,
        )
        let new_state = interactive_move_to_done(state)
        save_interactive_rebase_state(fs, git_dir, new_state)
        return {
          status: IRBConflict,
          commit_id: Some(label_id),
          message: "CONFLICT during merge: resolve conflicts then run 'git rebase --continue'",
          exit_code: 1,
        }
      }
      // No conflicts — create merge commit
      write_worktree_from_files(
        db,
        fs,
        rfs,
        root,
        git_dir,
        merged,
        remove_missing=true,
      )
      let entries = tree_files_to_index(db, rfs, merged)
      write_index_entries(fs, git_dir, entries)
      let tree_id = write_tree_from_index(fs, rfs, git_dir, entries)
      // Get author/committer info from original merge commit if available
      let (author, author_time, author_tz, committer, commit_time, committer_tz) = if entry.commit_hex.length() >
        0 {
        let orig_id = @bit.ObjectId::from_hex(entry.commit_hex)
        let info = rebase_parse_commit_full(db, rfs, orig_id)
        (
          info.author,
          info.author_time,
          info.author_tz,
          info.committer,
          info.commit_time,
          info.committer_tz,
        )
      } else {
        // Fallback: use HEAD commit's committer info
        let head_info = rebase_parse_commit_full(db, rfs, head_id)
        (
          head_info.author,
          head_info.author_time,
          head_info.author_tz,
          head_info.committer,
          head_info.commit_time,
          head_info.committer_tz,
        )
      }
      let new_commit = @bit.Commit::new(
        tree_id,
        [head_id, label_id],
        author,
        author_time,
        author_tz,
        committer,
        commit_time,
        committer_tz,
        merge_message,
      )
      let (new_id, compressed) = @bit.create_commit(new_commit)
      write_object_bytes(fs, git_dir, new_id, compressed)
      rebase_update_head(fs, rfs, git_dir, new_id)
      interactive_record_commit_mapping(state, rfs, git_dir, entry.commit_hex)
      let new_state = interactive_move_to_done(state)
      save_interactive_rebase_state(fs, git_dir, new_state)
      execute_interactive_todo(
        fs,
        rfs,
        root,
        new_state,
        message_editor,
        exec_runner~,
      )
    }
  }
}

///|
fn interactive_move_to_done(
  state : InteractiveRebaseState,
) -> InteractiveRebaseState {
  let new_done = state.done.copy()
  if state.todo.length() > 0 {
    new_done.push(state.todo[0])
  }
  let new_todo = []
  for i = 1; i < state.todo.length(); i = i + 1 {
    new_todo.push(state.todo[i])
  }
  {
    onto: state.onto,
    orig_head: state.orig_head,
    head_name: state.head_name,
    todo: new_todo,
    done: new_done,
    amend: false,
    squash_msg: state.squash_msg,
    update_refs: state.update_refs,
    commit_map: state.commit_map,
    labels: state.labels,
  }
}

// ============================================================================
// Interactive Rebase: cherry-pick a single commit
// ============================================================================

///|
fn interactive_cherry_pick(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  db : ObjectDb,
  commit_id : @bit.ObjectId,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let info = rebase_parse_commit_full(db, rfs, commit_id)
  let is_root_commit = info.parents.length() == 0
  let parent_id : @bit.ObjectId? = if info.parents.length() > 0 {
    Some(info.parents[0])
  } else {
    None
  }
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(base_id) else {
    // For root commits during --root rebase, HEAD may not exist yet.
    // In that case, just create the commit with empty tree as parent.
    if is_root_commit {
      // Write the root commit's tree directly as the new commit
      let new_commit = @bit.Commit::new(
        info.tree,
        [],
        info.author,
        info.author_time,
        info.author_tz,
        info.committer,
        info.commit_time,
        info.committer_tz,
        info.message,
      )
      let (new_id, compressed) = @bit.create_commit(new_commit)
      rebase_write_object(fs, rfs, git_dir, new_id, compressed)
      rebase_update_head(fs, rfs, git_dir, new_id)
      let tree_map = rebase_tree_map_from_tree(db, rfs, info.tree)
      rebase_write_worktree(fs, db, rfs, root, git_dir, tree_map)
      let entries = rebase_map_to_index(db, rfs, tree_map)
      write_index_entries(fs, git_dir, entries)
      return {
        status: IRBComplete,
        commit_id: Some(new_id),
        message: "",
        exit_code: 0,
      }
    }
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let base_map = rebase_tree_map(db, rfs, base_id)
  let parent_map : Map[String, TreeEntryInfo] = match parent_id {
    Some(pid) => rebase_tree_map(db, rfs, pid)
    None => Map([]) // Empty map for root commit (empty tree parent)
  }
  let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
  let changes = rebase_diff_maps(parent_map, commit_map)
  // Check if already applied
  if rebase_changes_already_applied(db, rfs, base_map, parent_map, changes) {
    return {
      status: IRBComplete,
      commit_id: Some(base_id),
      message: "already applied",
      exit_code: 0,
    }
  }
  // Apply changes with conflict detection
  let conflicts = rebase_apply_changes_with_conflicts(
    db, rfs, fs, root, base_map, parent_map, changes,
  )
  if conflicts.length() > 0 {
    // Write partial worktree (skip conflicting files)
    rebase_write_worktree_except(
      fs, db, rfs, root, git_dir, base_map, conflicts,
    )
    let entries = rebase_map_to_index(db, rfs, base_map)
    write_index_entries(fs, git_dir, entries)
    return {
      status: IRBConflict,
      commit_id: Some(commit_id),
      message: "CONFLICT: resolve conflicts then run 'git rebase --continue'",
      exit_code: 1,
    }
  }
  // Create new commit
  let new_tree = rebase_write_tree_from_map(fs, rfs, git_dir, base_map)
  let new_commit = @bit.Commit::new(
    new_tree,
    [base_id],
    info.author,
    info.author_time,
    info.author_tz,
    info.committer,
    info.commit_time,
    info.committer_tz,
    info.message,
  )
  let (new_id, compressed) = @bit.create_commit(new_commit)
  rebase_write_object(fs, rfs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update worktree + index
  rebase_write_worktree(fs, db, rfs, root, git_dir, base_map)
  let entries = rebase_map_to_index(db, rfs, base_map)
  write_index_entries(fs, git_dir, entries)
  { status: IRBComplete, commit_id: Some(new_id), message: "", exit_code: 0 }
}

// ============================================================================
// Interactive Rebase: amend HEAD message
// ============================================================================

///|
fn interactive_amend_head_message(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  db : ObjectDb,
  new_message : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(head_id) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let info = rebase_parse_commit_full(db, rfs, head_id)
  let new_commit = @bit.Commit::new(
    info.tree,
    info.parents,
    info.author,
    info.author_time,
    info.author_tz,
    info.committer,
    info.commit_time,
    info.committer_tz,
    new_message,
  )
  let (new_id, compressed) = @bit.create_commit(new_commit)
  rebase_write_object(fs, rfs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
}

// ============================================================================
// Interactive Rebase: squash into HEAD
// ============================================================================

///|
async fn interactive_squash_into_head(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  db : ObjectDb,
  commit_id : @bit.ObjectId,
  prev_squash_msg : String,
  fixup : Bool,
  message_editor : async (String) -> String?,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let info = rebase_parse_commit_full(db, rfs, commit_id)
  let parent_id = if info.parents.length() > 0 {
    info.parents[0]
  } else {
    raise @bit.GitError::InvalidObject("Cannot squash root commit")
  }
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(head_id) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let head_info = rebase_parse_commit_full(db, rfs, head_id)
  // Apply the commit's changes on top of HEAD
  let base_map = rebase_tree_map(db, rfs, head_id)
  let parent_map = rebase_tree_map(db, rfs, parent_id)
  let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
  let changes = rebase_diff_maps(parent_map, commit_map)
  let conflicts = rebase_apply_changes_with_conflicts(
    db, rfs, fs, root, base_map, parent_map, changes,
  )
  if conflicts.length() > 0 {
    rebase_write_worktree_except(
      fs, db, rfs, root, git_dir, base_map, conflicts,
    )
    let entries = rebase_map_to_index(db, rfs, base_map)
    write_index_entries(fs, git_dir, entries)
    return {
      status: IRBConflict,
      commit_id: Some(commit_id),
      message: "CONFLICT during squash",
      exit_code: 1,
    }
  }
  // Build combined message
  let head_msg = if prev_squash_msg.length() > 0 {
    prev_squash_msg
  } else {
    head_info.message
  }
  let combined_msg = if fixup {
    head_msg
  } else {
    head_msg + "\n\n" + info.message
  }
  // For squash (not fixup), let user edit the combined message
  let final_msg = if fixup {
    combined_msg
  } else {
    let edited_squash_msg = message_editor(combined_msg) catch { _ => None }
    match edited_squash_msg {
      Some(edited) => edited
      None => combined_msg
    }
  }
  // Create new commit replacing HEAD with squashed tree
  let new_tree = rebase_write_tree_from_map(fs, rfs, git_dir, base_map)
  let new_commit = @bit.Commit::new(
    new_tree,
    head_info.parents,
    head_info.author,
    head_info.author_time,
    head_info.author_tz,
    head_info.committer,
    head_info.commit_time,
    head_info.committer_tz,
    final_msg,
  )
  let (new_id, compressed) = @bit.create_commit(new_commit)
  rebase_write_object(fs, rfs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update worktree + index
  rebase_write_worktree(fs, db, rfs, root, git_dir, base_map)
  let entries = rebase_map_to_index(db, rfs, base_map)
  write_index_entries(fs, git_dir, entries)
  {
    status: IRBComplete,
    commit_id: Some(new_id),
    message: final_msg,
    exit_code: 0,
  }
}

// ============================================================================
// Interactive Rebase: continue / skip / abort
// ============================================================================

///|
pub async fn interactive_rebase_continue_impl(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  message_editor : async (String) -> String?,
  exec_runner? : (async (String) -> Int)? = None,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_interactive_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No interactive rebase in progress")
  }
  if s.amend {
    // Continuing after an "edit" stop: create commit from current worktree
    let db = ObjectDb::load(rfs, git_dir)
    let head = resolve_head_commit(rfs, git_dir)
    guard head is Some(head_id) else {
      raise @bit.GitError::InvalidObject("No HEAD commit")
    }
    let head_info = rebase_parse_commit_full(db, rfs, head_id)
    // Build tree from current index
    let entries = read_index_entries(rfs, git_dir)
    let new_tree = write_tree_from_entries(fs, rfs, git_dir, entries, None)
    // If tree changed, amend the commit
    if new_tree != head_info.tree {
      let new_commit = @bit.Commit::new(
        new_tree,
        head_info.parents,
        head_info.author,
        head_info.author_time,
        head_info.author_tz,
        head_info.committer,
        head_info.commit_time,
        head_info.committer_tz,
        head_info.message,
      )
      let (new_id, compressed) = @bit.create_commit(new_commit)
      rebase_write_object(fs, rfs, git_dir, new_id, compressed)
      rebase_update_head(fs, rfs, git_dir, new_id)
    }
    // Record commit mapping for update-refs after amend
    // The last done entry is the edit commit whose mapping was recorded before stop
    // After amend, HEAD may have changed, so update the mapping
    if s.update_refs.length() > 0 && s.done.length() > 0 {
      let last_done = s.done[s.done.length() - 1]
      interactive_record_commit_mapping(s, rfs, git_dir, last_done.commit_hex)
    }
    // Clear amend flag and continue
    let new_state : InteractiveRebaseState = { ..s, amend: false }
    save_interactive_rebase_state(fs, git_dir, new_state)
    return execute_interactive_todo(
      fs,
      rfs,
      root,
      new_state,
      message_editor,
      exec_runner~,
    )
  }
  // Continuing after a conflict: commit the resolved changes
  let db = ObjectDb::load(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(parent_id) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  // Build tree from current index (user resolved conflicts)
  let entries = read_index_entries(rfs, git_dir)
  let new_tree = write_tree_from_entries(fs, rfs, git_dir, entries, None)
  // Get info from the last done entry (the conflicting commit)
  if s.done.length() > 0 {
    let last_done = s.done[s.done.length() - 1]
    let commit_id = @bit.ObjectId::from_hex(last_done.commit_hex)
    let info = rebase_parse_commit_full(db, rfs, commit_id)
    let new_commit = @bit.Commit::new(
      new_tree,
      [parent_id],
      info.author,
      info.author_time,
      info.author_tz,
      info.committer,
      info.commit_time,
      info.committer_tz,
      info.message,
    )
    let (new_id, compressed) = @bit.create_commit(new_commit)
    rebase_write_object(fs, rfs, git_dir, new_id, compressed)
    rebase_update_head(fs, rfs, git_dir, new_id)
    // Record commit mapping for update-refs
    if s.update_refs.length() > 0 {
      s.commit_map[last_done.commit_hex] = new_id.to_hex()
    }
  }
  // Continue with remaining todo
  save_interactive_rebase_state(fs, git_dir, s)
  execute_interactive_todo(fs, rfs, root, s, message_editor, exec_runner~)
}

///|
pub async fn interactive_rebase_skip_impl(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  message_editor : async (String) -> String?,
  exec_runner? : (async (String) -> Int)? = None,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_interactive_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No interactive rebase in progress")
  }
  // Reset worktree to current HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(h) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let tree_map = rebase_tree_map(db, rfs, h)
  rebase_write_worktree(fs, db, rfs, root, git_dir, tree_map)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
  // Clear amend flag if set
  let new_state : InteractiveRebaseState = { ..s, amend: false }
  save_interactive_rebase_state(fs, git_dir, new_state)
  execute_interactive_todo(
    fs,
    rfs,
    root,
    new_state,
    message_editor,
    exec_runner~,
  )
}

///|
pub fn interactive_rebase_abort_impl(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_interactive_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No interactive rebase in progress")
  }
  // Restore original HEAD
  let head_path = join_path(git_dir, "HEAD")
  if s.head_name.length() > 0 {
    fs.write_string(head_path, "ref: " + s.head_name + "\n")
    let ref_path = join_path(git_dir, s.head_name)
    let dir = parent_dir(ref_path)
    if dir.length() > 0 {
      fs.mkdir_p(dir)
    }
    fs.write_string(ref_path, s.orig_head.to_hex() + "\n")
  } else {
    fs.write_string(head_path, s.orig_head.to_hex() + "\n")
  }
  // Restore worktree to original HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let tree_map = rebase_tree_map(db, rfs, s.orig_head)
  rebase_write_worktree(fs, db, rfs, root, git_dir, tree_map) catch {
    _ => ()
  }
  let entries = rebase_map_to_index(db, rfs, tree_map) catch { _ => [] }
  write_index_entries(fs, git_dir, entries) catch {
    _ => ()
  }
  // Clear rebase state
  clear_rebase_state(fs, rfs, git_dir)
}

// ============================================================================
// Interactive Rebase: finish (restore branch, clean up)
// ============================================================================

///|
fn interactive_rebase_finish(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  state : InteractiveRebaseState,
) -> InteractiveRebaseResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(final_id) else {
    raise @bit.GitError::InvalidObject("No HEAD after rebase")
  }
  // Update worktree + index to final state
  let final_map = rebase_tree_map(db, rfs, final_id)
  rebase_write_worktree(fs, db, rfs, root, git_dir, final_map)
  let entries = rebase_map_to_index(db, rfs, final_map)
  write_index_entries(fs, git_dir, entries)
  // Update refs that pointed to commits in the rebase chain
  if state.update_refs.length() > 0 {
    for ref_path, old_hex in state.update_refs {
      match state.commit_map.get(old_hex) {
        Some(new_hex) if new_hex.length() > 0 => {
          let full_ref_path = join_path(git_dir, ref_path)
          let dir = parent_dir(full_ref_path)
          if dir.length() > 0 {
            fs.mkdir_p(dir)
          }
          fs.write_string(full_ref_path, new_hex + "\n")
        }
        _ => ()
      }
    }
  }
  // Restore branch ref if applicable
  if state.head_name.length() > 0 {
    let head_path = join_path(git_dir, "HEAD")
    fs.write_string(head_path, "ref: " + state.head_name + "\n")
    let ref_path = join_path(git_dir, state.head_name)
    let dir = parent_dir(ref_path)
    if dir.length() > 0 {
      fs.mkdir_p(dir)
    }
    fs.write_string(ref_path, final_id.to_hex() + "\n")
  }
  // Clean up rebase state
  clear_rebase_state(fs, rfs, git_dir)
  {
    status: IRBComplete,
    commit_id: Some(final_id),
    message: "Successfully rebased.",
    exit_code: 0,
  }
}

///|
/// Check if an interactive rebase is in progress.
pub fn is_interactive_rebase_in_progress(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let rebase_dir = join_path(git_dir, "rebase-merge")
  rfs.is_dir(rebase_dir) && rfs.is_file(join_path(rebase_dir, "interactive"))
}
