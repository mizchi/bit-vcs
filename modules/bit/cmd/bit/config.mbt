///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let normalized_args = normalize_config_args(args)
  // Parse arguments
  let mut get_mode = false
  let mut get_all_mode = false
  let mut get_bool = false
  let mut get_int = false
  let mut get_bool_or_int = false
  let mut get_path = false
  let mut get_expiry_date = false
  let mut get_color = false
  let mut get_color_mode = false
  let mut get_regexp_mode = false
  let mut list_mode = false
  let mut unset_mode = false
  let mut unset_all = false
  let mut replace_all_mode = false
  let mut add_mode = false
  let mut remove_section_mode = false
  let mut rename_section_mode = false
  let mut fixed_value_mode = false
  let mut edit_mode = false
  let mut show_scope = false
  let mut show_origin = false
  let mut name_only = false
  let mut null_terminator = false
  let mut local_mode = false
  let mut global_mode = false
  let mut system_mode = false
  let mut worktree_mode = false
  let mut config_path_override : String? = None
  let mut expect_config_path = false
  let mut default_value : String? = None
  let mut expect_default_value = false
  let mut comment : String? = None
  let mut expect_comment = false
  let mut expect_value_pattern = false
  let mut expect_type_value = false
  let mut config_type_spec : String? = None
  let mut key : String? = None
  let mut value : String? = None
  let mut value_pattern : String? = None
  let mut saw_get_mode = false
  let mut saw_get_all_mode = false
  for arg in normalized_args {
    if expect_config_path {
      config_path_override = Some(arg)
      expect_config_path = false
      continue
    }
    if expect_default_value {
      default_value = Some(arg)
      expect_default_value = false
      continue
    }
    if expect_comment {
      comment = Some(arg)
      expect_comment = false
      continue
    }
    if expect_value_pattern {
      value_pattern = Some(arg)
      expect_value_pattern = false
      continue
    }
    if expect_type_value {
      config_type_spec = Some(merge_config_type_spec(config_type_spec, arg))
      expect_type_value = false
      continue
    }
    match arg {
      "--local" => local_mode = true
      "--global" => global_mode = true
      "--system" => system_mode = true
      "--worktree" => worktree_mode = true
      "-f" | "--file" => expect_config_path = true
      _ if arg.has_prefix("--file=") =>
        config_path_override = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
      "--default" => expect_default_value = true
      _ if arg.has_prefix("--default=") =>
        default_value = Some(
          String::unsafe_substring(arg, start=10, end=arg.length()),
        )
      "--comment" => expect_comment = true
      _ if arg.has_prefix("--comment=") =>
        comment = Some(
          String::unsafe_substring(arg, start=10, end=arg.length()),
        )
      "--value" => expect_value_pattern = true
      _ if arg.has_prefix("--value=") =>
        value_pattern = Some(
          String::unsafe_substring(arg, start=8, end=arg.length()),
        )
      "--get" => {
        get_mode = true
        saw_get_mode = true
      }
      "--get-all" => {
        get_mode = true
        get_all_mode = true
        saw_get_all_mode = true
      }
      "--get-regexp" => get_regexp_mode = true
      "--bool" =>
        config_type_spec = Some(
          merge_config_type_spec(config_type_spec, "bool"),
        )
      "--int" =>
        config_type_spec = Some(merge_config_type_spec(config_type_spec, "int"))
      "--bool-or-int" =>
        config_type_spec = Some(
          merge_config_type_spec(config_type_spec, "bool-or-int"),
        )
      "--path" =>
        config_type_spec = Some(
          merge_config_type_spec(config_type_spec, "path"),
        )
      "--expiry-date" =>
        config_type_spec = Some(
          merge_config_type_spec(config_type_spec, "expiry-date"),
        )
      "--type" => expect_type_value = true
      _ if arg.has_prefix("--type=") =>
        config_type_spec = Some(
          merge_config_type_spec(
            config_type_spec,
            String::unsafe_substring(arg, start=7, end=arg.length()),
          ),
        )
      "--no-type" => config_type_spec = None
      "--get-color" => {
        get_mode = true
        get_color_mode = true
        config_type_spec = Some(
          merge_config_type_spec(config_type_spec, "color"),
        )
      }
      "--list" | "-l" => list_mode = true
      "--unset" => unset_mode = true
      "--unset-all" => unset_all = true
      "--replace-all" => replace_all_mode = true
      "--add" => add_mode = true
      "--remove-section" => remove_section_mode = true
      "--rename-section" => rename_section_mode = true
      "--fixed-value" => fixed_value_mode = true
      "--name-only" => name_only = true
      "--null" | "-z" => null_terminator = true
      "-e" | "--edit" | "edit" => edit_mode = true
      "--show-scope" => show_scope = true
      "--show-origin" => show_origin = true
      "--get-urlmatch" => {
        delegate_config_to_real_git(args)
        return
      }
      _ if arg.has_prefix("--url=") ||
        arg.has_prefix("--blob=") ||
        arg == "--blob" ||
        arg == "--includes" => {
        delegate_config_to_real_git(args)
        return
      }
      "--no-get" => {
        eprint_line("error: unknown option `no-get'")
        @sys.exit(129)
      }
      _ if arg.has_prefix("-") =>
        if key is Some(_) && value is None {
          // `git config <key> -value` treats `-value` as a value.
          value = Some(arg)
        } else {
          warn_unimplemented_arg("config", arg)
        }
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        } else if value_pattern is None {
          value_pattern = Some(arg)
        }
    }
  }
  if expect_config_path {
    raise @bitcore.GitError::InvalidObject("option '-f' requires a value")
  }
  if expect_default_value {
    raise @bitcore.GitError::InvalidObject(
      "option '--default' requires a value",
    )
  }
  if expect_comment {
    raise @bitcore.GitError::InvalidObject(
      "option '--comment' requires a value",
    )
  }
  if expect_value_pattern {
    raise @bitcore.GitError::InvalidObject("option '--value' requires a value")
  }
  if expect_type_value {
    raise @bitcore.GitError::InvalidObject("option '--type' requires a value")
  }
  get_bool = false
  get_int = false
  get_bool_or_int = false
  get_path = false
  get_expiry_date = false
  get_color = false
  match config_type_spec {
    Some("bool") => get_bool = true
    Some("int") => get_int = true
    Some("bool-or-int") => get_bool_or_int = true
    Some("path") => get_path = true
    Some("expiry-date") => get_expiry_date = true
    Some("color") => get_color = true
    _ => ()
  }
  if saw_get_mode && saw_get_all_mode {
    eprint_line(
      "error: options '--get-all' and '--get' cannot be used together",
    )
    @sys.exit(129)
  }
  match comment {
    Some(c) =>
      if c.contains("\n") {
        raise @bitcore.GitError::InvalidObject(
          "invalid comment: must not contain newline",
        )
      }
    None => ()
  }
  if global_mode && system_mode {
    raise @bitcore.GitError::InvalidObject(
      "only one config scope can be specified",
    )
  }
  if local_mode && (global_mode || system_mode) {
    raise @bitcore.GitError::InvalidObject(
      "--local cannot be used with --global or --system",
    )
  }
  if worktree_mode && (global_mode || system_mode) {
    raise @bitcore.GitError::InvalidObject(
      "--worktree cannot be used with --global or --system",
    )
  }
  // --local / --worktree require being inside a repository
  if (local_mode || worktree_mode) && config_path_override is None {
    let root = get_work_root()
    if find_repo_root(root) is None {
      let flag = if worktree_mode { "--worktree" } else { "--local" }
      eprint_line("fatal: \{flag} can only be used inside a git repository")
      @sys.exit(128)
    }
  }
  let config_path = match config_path_override {
    Some(path) => if path == "-" { "-" } else { resolve_in_cwd(path) }
    None =>
      if global_mode {
        match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
          Some(path) => path
          None =>
            match @sys.get_env_var("HOME") {
              Some(home) => home + "/.gitconfig"
              None => ".gitconfig"
            }
        }
      } else if system_mode {
        @sys.get_env_var("GIT_CONFIG_SYSTEM").unwrap_or("/etc/gitconfig")
      } else {
        // GIT_CONFIG environment variable overrides default path
        match @sys.get_env_var("GIT_CONFIG") {
          Some(path) => if path == "-" { "-" } else { resolve_in_cwd(path) }
          None => {
            let rfs : &@bitcore.RepoFileSystem = fs
            let root = get_work_root()
            let git_dir = resolve_git_dir(rfs, root)
            if worktree_mode {
              git_dir + "/config.worktree"
            } else {
              resolve_common_git_dir(rfs, git_dir) + "/config"
            }
          }
        }
      }
  }
  let write_to_config = edit_mode ||
    rename_section_mode ||
    remove_section_mode ||
    replace_all_mode ||
    unset_mode ||
    unset_all ||
    (!get_mode && value is Some(_))
  if config_path == "-" && write_to_config {
    eprint_line("fatal: writing to stdin is not supported")
    @sys.exit(1)
  }
  let mut stdin_content : String? = None
  // Handle --edit
  if edit_mode {
    // Editor precedence: GIT_EDITOR > core.editor > VISUAL > EDITOR > vi
    let editor = match @sys.get_env_var("GIT_EDITOR") {
      Some(e) => e
      None => {
        // Try core.editor from repo config
        let rfs : &@bitcore.RepoFileSystem = fs
        let root = get_work_root()
        let git_dir = resolve_git_dir(rfs, root)
        let common_git_dir = resolve_common_git_dir(rfs, git_dir)
        let core_editor = get_config_value(
          fs,
          common_git_dir + "/config",
          "core.editor",
          None,
          false,
        )
        match core_editor {
          Some(e) => e
          None =>
            match @sys.get_env_var("VISUAL") {
              Some(e) => e
              None => @sys.get_env_var("EDITOR").unwrap_or("vi")
            }
        }
      }
    }
    // Quote config_path for shell safety (spaces in paths)
    let quoted_path = "'" + config_path.replace(old="'", new="'\\''") + "'"
    let status = @process.run(
      "/bin/sh",
      ["-c", editor + " " + quoted_path],
      inherit_env=true,
      stdin=@stdio.stdin,
      stdout=@stdio.stdout,
      stderr=@stdio.stderr,
    )
    @sys.exit(status)
  }
  // Validate config syntax for read operations
  let rfs2 : &@bitcore.RepoFileSystem = fs
  if list_mode || get_mode || get_regexp_mode {
    if config_path == "-" {
      let raw_content = decode_bytes(read_all_stdin())
      validate_config_file("standard input", raw_content)
      stdin_content = Some(raw_content)
    } else if rfs2.is_file(config_path) {
      let raw_content = decode_bytes(rfs2.read_file(config_path))
      validate_config_file(config_path, raw_content)
    }
  }
  // Check if specified config file exists (required for explicit scope modes in read operations)
  let is_read_op = list_mode || get_mode || get_all_mode || get_regexp_mode
  if is_read_op && config_path != "-" && !@fs.path_exists(config_path) {
    if config_path_override is Some(_) ||
      (global_mode && @sys.get_env_var("GIT_CONFIG_GLOBAL") is Some(_)) ||
      (system_mode && @sys.get_env_var("GIT_CONFIG_SYSTEM") is Some(_)) {
      eprint_line(
        "fatal: unable to read config file '\{config_path}': No such file or directory",
      )
      @sys.exit(128)
    }
  }
  // Handle --list
  if list_mode {
    if fixed_value_mode {
      raise @bitcore.GitError::InvalidObject(
        "--fixed-value is not supported for --list",
      )
    }
    let need_multi_source = (show_scope || show_origin) &&
      config_path_override is None &&
      !global_mode &&
      !system_mode &&
      !local_mode
    if need_multi_source {
      // Multi-source list with scope/origin prefix
      let rfs3 : &@bitcore.RepoFileSystem = fs
      let nosystem = @sys.get_env_var("GIT_CONFIG_NOSYSTEM")
      if nosystem is None || nosystem == Some("false") {
        let sys_path = @sys.get_env_var("GIT_CONFIG_SYSTEM").unwrap_or(
          "/etc/gitconfig",
        )
        if rfs3.is_file(sys_path) {
          let scope = if show_scope { "system" } else { "" }
          let origin = if show_origin {
            "file:" + quote_origin_path(sys_path)
          } else {
            ""
          }
          list_config(fs, sys_path, name_only, null_terminator, scope~, origin~)
        }
      }
      // Global: GIT_CONFIG_GLOBAL or XDG + HOME
      let global_path = match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
        Some(p) => [p]
        None => {
          let paths : Array[String] = []
          match @sys.get_env_var("HOME") {
            Some(home) => {
              let xdg = home + "/.config/git/config"
              if rfs3.is_file(xdg) {
                paths.push(xdg)
              }
              let gitconfig = home + "/.gitconfig"
              if rfs3.is_file(gitconfig) {
                paths.push(gitconfig)
              }
            }
            None => ()
          }
          paths
        }
      }
      for gp in global_path {
        if rfs3.is_file(gp) {
          let scope = if show_scope { "global" } else { "" }
          let origin = if show_origin {
            "file:" + quote_origin_path(gp)
          } else {
            ""
          }
          list_config(fs, gp, name_only, null_terminator, scope~, origin~)
        }
      }
      // Local
      let root = get_work_root()
      let git_dir = resolve_git_dir(rfs3, root)
      let local_path = resolve_common_git_dir(rfs3, git_dir) + "/config"
      if rfs3.is_file(local_path) {
        let scope = if show_scope { "local" } else { "" }
        let origin = if show_origin {
          "file:" + quote_origin_path(make_relative_to_cwd(local_path))
        } else {
          ""
        }
        list_config(fs, local_path, name_only, null_terminator, scope~, origin~)
      }
      return
    }
    if config_path == "-" {
      match stdin_content {
        Some(content) => {
          let scope = if show_scope { "command line" } else { "" }
          let origin = if show_origin { "standard input:" } else { "" }
          list_config_from_content(
            content,
            name_only,
            null_terminator,
            scope~,
            origin~,
          )
        }
        None => @sys.exit(1)
      }
    } else if fs.is_file(config_path) {
      let scope = if show_scope {
        if global_mode {
          "global"
        } else if system_mode {
          "system"
        } else if local_mode || config_path_override is None {
          "local"
        } else {
          "command line"
        }
      } else {
        ""
      }
      let origin = if show_origin {
        "file:" + quote_origin_path(make_relative_to_cwd(config_path))
      } else {
        ""
      }
      list_config(fs, config_path, name_only, null_terminator, scope~, origin~)
    } else if config_path_override is Some(_) {
      @sys.exit(1)
    }
    return
  }
  // Handle --get-regexp
  if get_regexp_mode {
    guard key is Some(k) else {
      raise @bitcore.GitError::InvalidObject("key pattern required")
    }
    let vp = match value_pattern {
      Some(p) => Some(p)
      None => value
    }
    if fixed_value_mode && vp is None {
      raise @bitcore.GitError::InvalidObject("value required for --fixed-value")
    }
    let regexp_scope = if show_scope {
      if global_mode {
        "global"
      } else if system_mode {
        "system"
      } else {
        "local"
      }
    } else {
      ""
    }
    let regexp_origin = if show_origin {
      if config_path == "-" {
        "standard input:"
      } else {
        "file:" + quote_origin_path(make_relative_to_cwd(config_path))
      }
    } else {
      ""
    }
    if config_path == "-" {
      let found = match stdin_content {
        Some(content) =>
          get_regexp_config_from_content(
            content,
            k,
            vp,
            fixed_value_mode,
            get_bool,
            get_int,
            name_only,
            null_terminator,
            "standard input",
            scope=regexp_scope,
            origin=regexp_origin,
          )
        None => false
      }
      if !found {
        @sys.exit(1)
      }
    } else {
      // Multi-source get-regexp when no explicit scope
      let need_multi_source = (show_scope || show_origin) &&
        config_path_override is None &&
        !global_mode &&
        !system_mode &&
        !local_mode
      let mut found = false
      if need_multi_source {
        let rfs4 : &@bitcore.RepoFileSystem = fs
        let nosystem = @sys.get_env_var("GIT_CONFIG_NOSYSTEM")
        if nosystem is None || nosystem == Some("false") {
          let sys_path = @sys.get_env_var("GIT_CONFIG_SYSTEM").unwrap_or(
            "/etc/gitconfig",
          )
          if rfs4.is_file(sys_path) {
            let sc = if show_scope { "system" } else { "" }
            let or_ = if show_origin {
              "file:" + quote_origin_path(sys_path)
            } else {
              ""
            }
            if get_regexp_config(
                fs,
                sys_path,
                k,
                vp,
                fixed_value_mode,
                get_bool,
                get_int,
                name_only,
                null_terminator,
                scope=sc,
                origin=or_,
              ) {
              found = true
            }
          }
        }
        let global_paths = match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
          Some(p) => [p]
          None => {
            let paths : Array[String] = []
            match @sys.get_env_var("HOME") {
              Some(home) => {
                let xdg = home + "/.config/git/config"
                if rfs4.is_file(xdg) {
                  paths.push(xdg)
                }
                let gitconfig = home + "/.gitconfig"
                if rfs4.is_file(gitconfig) {
                  paths.push(gitconfig)
                }
              }
              None => ()
            }
            paths
          }
        }
        for gp in global_paths {
          if rfs4.is_file(gp) {
            let sc = if show_scope { "global" } else { "" }
            let or_ = if show_origin {
              "file:" + quote_origin_path(gp)
            } else {
              ""
            }
            if get_regexp_config(
                fs,
                gp,
                k,
                vp,
                fixed_value_mode,
                get_bool,
                get_int,
                name_only,
                null_terminator,
                scope=sc,
                origin=or_,
              ) {
              found = true
            }
          }
        }
        if rfs4.is_file(config_path) {
          let sc = if show_scope { "local" } else { "" }
          let or_ = if show_origin {
            "file:" + quote_origin_path(make_relative_to_cwd(config_path))
          } else {
            ""
          }
          if get_regexp_config(
              fs,
              config_path,
              k,
              vp,
              fixed_value_mode,
              get_bool,
              get_int,
              name_only,
              null_terminator,
              scope=sc,
              origin=or_,
            ) {
            found = true
          }
        }
      } else if fs.is_file(config_path) {
        found = get_regexp_config(
          fs,
          config_path,
          k,
          vp,
          fixed_value_mode,
          get_bool,
          get_int,
          name_only,
          null_terminator,
          scope=regexp_scope,
          origin=regexp_origin,
        )
      }
      if !found {
        @sys.exit(1)
      }
    }
    return
  }
  // Handle --rename-section
  if rename_section_mode {
    if fixed_value_mode {
      raise @bitcore.GitError::InvalidObject(
        "--fixed-value is not supported for --rename-section",
      )
    }
    guard key is Some(old_name) else {
      raise @bitcore.GitError::InvalidObject("section name required")
    }
    guard value is Some(new_name) else {
      raise @bitcore.GitError::InvalidObject("new section name required")
    }
    rename_config_section(fs, config_path, old_name, new_name)
    return
  }
  if remove_section_mode {
    if fixed_value_mode {
      raise @bitcore.GitError::InvalidObject(
        "--fixed-value is not supported for --remove-section",
      )
    }
    guard key is Some(section_key) else {
      raise @bitcore.GitError::InvalidObject("section name required")
    }
    remove_config_section_file(fs, config_path, section_key)
    return
  }
  if get_color_mode && default_value is None && value_pattern is None {
    match value {
      Some(v) => {
        default_value = Some(v)
        value = None
      }
      None => ()
    }
  }
  guard key is Some(k) else {
    // No key given: check if any action mode was specified
    if !get_mode &&
      !get_all_mode &&
      !unset_mode &&
      !unset_all &&
      !replace_all_mode &&
      !remove_section_mode &&
      !rename_section_mode &&
      !get_regexp_mode {
      eprint_line("error: no action specified")
      @sys.exit(2)
    }
    eprint_line("error: key does not contain a section: ")
    @sys.exit(2)
  }
  // Handle --replace-all
  if replace_all_mode {
    guard value is Some(v) else {
      raise @bitcore.GitError::InvalidObject("value required for --replace-all")
    }
    if fixed_value_mode && value_pattern is None {
      raise @bitcore.GitError::InvalidObject("value required for --fixed-value")
    }
    let write_value = if get_bool {
      format_bool_for_write(v)
    } else if get_bool_or_int {
      format_bool_or_int_for_write(v)
    } else if get_int {
      format_int_for_write(v)
    } else if get_color {
      format_color_for_write(v)
    } else {
      v
    }
    replace_all_config(
      fs, config_path, k, write_value, value_pattern, fixed_value_mode, comment,
    )
    return
  }
  // Handle --unset / --unset-all
  if unset_mode || unset_all {
    let pattern_arg = match value_pattern {
      Some(p) => Some(p)
      None => value
    }
    let vp : String? = if fixed_value_mode {
      if pattern_arg is None {
        raise @bitcore.GitError::InvalidObject(
          "value required for --fixed-value",
        )
      }
      pattern_arg
    } else {
      pattern_arg
    }
    unset_config(fs, config_path, k, vp, fixed_value_mode, unset_all)
    return
  }
  if get_mode || value is None {
    // Compute scope/origin prefix for get value output
    let get_scope_prefix = if show_scope {
      let scope_name = if global_mode {
        "global"
      } else if system_mode {
        "system"
      } else {
        "local"
      }
      scope_name + "\t"
    } else {
      ""
    }
    let get_origin_prefix = if show_origin {
      if config_path == "-" {
        "standard input:\t"
      } else {
        "file:" + quote_origin_path(make_relative_to_cwd(config_path)) + "\t"
      }
    } else {
      ""
    }
    let get_default_scope_prefix = if show_scope { "command\t" } else { "" }
    let get_default_origin_prefix = if show_origin {
      "command line:\t"
    } else {
      ""
    }
    // If key is empty/invalid and we have a default, return default directly
    if parse_config_key(k) is None && default_value is Some(def) {
      let formatted = format_config_output_value(
        def,
        get_bool,
        get_int,
        get_bool_or_int,
        get_path,
        get_expiry_date,
        get_color,
        Some(k),
        (None : String?),
        (None : Int?),
      )
      let prefixed = get_default_origin_prefix +
        get_default_scope_prefix +
        formatted
      if null_terminator {
        print_nul_terminated(prefixed)
      } else {
        print_line(prefixed)
      }
      return
    }
    // Read config
    if fixed_value_mode {
      let has_pattern = value_pattern is Some(_) || value is Some(_)
      if !has_pattern {
        raise @bitcore.GitError::InvalidObject(
          "value required for --fixed-value",
        )
      }
    }
    if get_all_mode {
      let vp : String? = if get_mode && !get_color_mode {
        match value_pattern {
          Some(p) => Some(p)
          None => value
        }
      } else {
        None
      }
      let result = if config_path == "-" {
        match stdin_content {
          Some(content) =>
            get_all_config_values_from_content(content, k, vp, fixed_value_mode)
          None => []
        }
      } else if fs.is_file(config_path) {
        get_all_config_values(fs, config_path, k, vp, fixed_value_mode)
      } else {
        []
      }
      if result.length() == 0 {
        match default_value {
          Some(def) => {
            let formatted = format_config_output_value(
              def,
              get_bool,
              get_int,
              get_bool_or_int,
              get_path,
              get_expiry_date,
              get_color,
              Some(k),
              (None : String?),
              (None : Int?),
            )
            let prefixed = get_default_origin_prefix +
              get_default_scope_prefix +
              formatted
            if null_terminator {
              print_nul_terminated(prefixed)
            } else {
              print_line(prefixed)
            }
          }
          None => @sys.exit(1)
        }
      } else {
        for v in result {
          let source_name : String? = if config_path == "-" {
            Some("standard input")
          } else {
            Some(config_path)
          }
          let formatted = format_config_output_value(
            v,
            get_bool,
            get_int,
            get_bool_or_int,
            get_path,
            get_expiry_date,
            get_color,
            Some(k),
            source_name,
            (None : Int?),
          )
          let prefixed = get_origin_prefix + get_scope_prefix + formatted
          if null_terminator {
            print_nul_terminated(prefixed)
          } else {
            print_line(prefixed)
          }
        }
      }
    } else {
      let vp : String? = if get_mode && !get_color_mode {
        match value_pattern {
          Some(p) => Some(p)
          None => value
        }
      } else {
        None
      }
      let mut value_source : String? = None
      let result = match get_config_override(k) {
        Some(v) => Some(v)
        None =>
          if config_path == "-" {
            value_source = Some("standard input")
            match stdin_content {
              Some(content) =>
                get_config_value_from_content(content, k, vp, fixed_value_mode)
              None => (None : String?)
            }
          } else if fs.is_file(config_path) {
            value_source = Some(config_path)
            get_config_value(fs, config_path, k, vp, fixed_value_mode)
          } else {
            (None : String?)
          }
      }
      match result {
        Some(val) => {
          let line_hint : Int? = if get_path && is_config_novalue(val) {
            match value_source {
              Some(src) =>
                if src == "standard input" {
                  match stdin_content {
                    Some(content) =>
                      find_config_key_line_from_content(content, k)
                    None => (None : Int?)
                  }
                } else if fs.is_file(src) {
                  let raw = decode_bytes(fs.read_file(src))
                  find_config_key_line_from_content(raw, k)
                } else {
                  (None : Int?)
                }
              None => (None : Int?)
            }
          } else {
            (None : Int?)
          }
          let formatted = format_config_output_value(
            val,
            get_bool,
            get_int,
            get_bool_or_int,
            get_path,
            get_expiry_date,
            get_color,
            Some(k),
            value_source,
            line_hint,
          )
          let prefixed = get_origin_prefix + get_scope_prefix + formatted
          if null_terminator {
            print_nul_terminated(prefixed)
          } else {
            print_line(prefixed)
          }
        }
        None =>
          match default_value {
            Some(def) => {
              let formatted = format_config_output_value(
                def,
                get_bool,
                get_int,
                get_bool_or_int,
                get_path,
                get_expiry_date,
                get_color,
                Some(k),
                (None : String?),
                (None : Int?),
              )
              let prefixed = get_default_origin_prefix +
                get_default_scope_prefix +
                formatted
              if null_terminator {
                print_nul_terminated(prefixed)
              } else {
                print_line(prefixed)
              }
            }
            None =>
              // Key not found - exit silently with code 1 (git behavior)
              @sys.exit(1)
          }
      }
    }
  } else {
    // Write config
    if add_mode && fixed_value_mode {
      raise @bitcore.GitError::InvalidObject(
        "--fixed-value is not supported for --add",
      )
    }
    if fixed_value_mode && value_pattern is None {
      raise @bitcore.GitError::InvalidObject("value required for --fixed-value")
    }
    guard value is Some(v) else { return }
    let write_value = if get_bool {
      format_bool_for_write(v)
    } else if get_bool_or_int {
      format_bool_or_int_for_write(v)
    } else if get_int {
      format_int_for_write(v)
    } else if get_color {
      format_color_for_write(v)
    } else {
      v
    }
    if fixed_value_mode {
      set_config_with_fixed_value(
        fs, config_path, k, write_value, add_mode, comment, value_pattern, fixed_value_mode,
      )
    } else {
      set_config(
        fs, config_path, k, write_value, add_mode, comment, value_pattern,
      )
    }
  }
}

///|
fn normalize_config_args(args : Array[String]) -> Array[String] {
  if args.length() == 0 {
    return args
  }
  let normalized : Array[String] = []
  match args[0] {
    "set" => {
      for i in 1..<args.length() {
        let arg = args[i]
        if arg == "--append" {
          normalized.push("--add")
        } else if arg == "--all" {
          normalized.push("--replace-all")
        } else {
          normalized.push(arg)
        }
      }
      normalized
    }
    "unset" => {
      let mut has_all = false
      normalized.push("--unset")
      for i in 1..<args.length() {
        if args[i] == "--all" {
          // Replace --unset with --unset-all
          has_all = true
        } else {
          normalized.push(args[i])
        }
      }
      if has_all {
        // Replace first --unset with --unset-all
        normalized[0] = "--unset-all"
      }
      normalized
    }
    "get" => {
      let mut has_all = false
      let mut has_regexp = false
      let mut has_show_names = false
      for i in 1..<args.length() {
        let arg = args[i]
        if arg == "--all" {
          has_all = true
        } else if arg == "--regexp" {
          has_regexp = true
        } else if arg == "--show-names" {
          has_show_names = true
        } else if arg.has_prefix("--value=") {
          normalized.push(arg)
        } else if arg == "--value" {
          normalized.push(arg)
        } else {
          normalized.push(arg)
        }
      }
      if has_regexp {
        // --show-names is default for --get-regexp (shows key + value)
        // so we drop it; only convert to --name-only in non-regexp modes
        let result : Array[String] = ["--get-regexp"]
        for a in normalized {
          result.push(a)
        }
        result
      } else if has_all {
        let result : Array[String] = ["--get-all"]
        if has_show_names {
          result.push("--name-only")
        }
        for a in normalized {
          result.push(a)
        }
        result
      } else {
        let result : Array[String] = ["--get"]
        if has_show_names {
          result.push("--name-only")
        }
        for a in normalized {
          result.push(a)
        }
        result
      }
    }
    "list" => {
      normalized.push("--list")
      for i in 1..<args.length() {
        normalized.push(args[i])
      }
      normalized
    }
    "rename-section" => {
      let result : Array[String] = ["--rename-section"]
      for i in 1..<args.length() {
        result.push(args[i])
      }
      result
    }
    "remove-section" => {
      let result : Array[String] = ["--remove-section"]
      for i in 1..<args.length() {
        result.push(args[i])
      }
      result
    }
    "edit" => {
      let result : Array[String] = ["--edit"]
      for i in 1..<args.length() {
        result.push(args[i])
      }
      result
    }
    _ => args
  }
}

///|
/// Sentinel value for config keys with no '=' sign (value-less keys).
/// Internal to config.mbt — external callers should not see this.
fn config_novalue() -> String {
  @config_parse.config_novalue()
}

///|
fn is_config_novalue(s : String) -> Bool {
  @config_parse.is_config_novalue(s)
}

///|
fn normalize_config_type_name(name : String) -> String raise Error {
  match name.to_lower() {
    "bool" => "bool"
    "int" => "int"
    "bool-or-int" => "bool-or-int"
    "path" => "path"
    "expiry-date" => "expiry-date"
    "color" => "color"
    other =>
      raise @bitcore.GitError::InvalidObject(
        "unrecognized --type argument '\{other}'",
      )
  }
}

///|
fn merge_config_type_spec(
  current : String?,
  next_name : String,
) -> String raise Error {
  let normalized = normalize_config_type_name(next_name)
  match current {
    None => normalized
    Some(cur) =>
      if cur == normalized {
        cur
      } else {
        raise @bitcore.GitError::InvalidObject("only one type at a time")
      }
  }
}

///|
fn trim_chars(s : String, chars : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if code_in_string(c, chars) {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if code_in_string(c, chars) {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
fn code_in_string(c : UInt16, s : String) -> Bool {
  for i in 0..<s.length() {
    if s.unsafe_get(i) == c {
      return true
    }
  }
  false
}

///|
fn split_config_lines_preserve_cr(content : String) -> Array[String] {
  let lines : Array[String] = []
  let mut start = 0
  for i, c in content {
    if c == '\n' {
      lines.push(String::unsafe_substring(content, start~, end=i))
      start = i + 1
    }
  }
  if start <= content.length() {
    lines.push(String::unsafe_substring(content, start~, end=content.length()))
  }
  lines
}

///|
/// Parse a section header line like `[section]`, `[section "sub"]`,
/// `[section.sub]` (dot notation), or `[section] rest`.
/// Returns (section_name, subsection?, rest_after_bracket, is_dot_form) or None.
/// For dot notation `[section.Sub]`, the subsection is LOWERCASED (git compat).
/// For quoted `[section "Sub"]`, the subsection is preserved as-is.
fn parse_section_header_line(line : String) -> (String, String?, String, Bool)? {
  @config_parse.parse_section_header_line(line)
}

///|
fn is_valid_section_name(name : String) -> Bool {
  @config_parse.is_valid_section_name(name)
}

///|
/// Validate a config file and exit(128) with error if syntax is invalid.
/// Checks: unclosed section headers, unclosed quotes, bare keys without =.
async fn validate_config_file(config_path : String, content : String) -> Unit {
  let raw_lines = split_config_lines_preserve_cr(content)
  let lines = preprocess_config_lines_with_line_numbers(raw_lines)
  let location = if config_path == "standard input" {
    "standard input"
  } else {
    "file " + config_path
  }
  let mut in_section = false
  for line_info in lines {
    let (line, line_num) = line_info
    let trimmed = trim_string(line)
    // Skip empty lines and comments
    if trimmed.length() == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
      continue
    }
    // Section header
    if trimmed[0] == '[' {
      match trimmed.find("]") {
        None => {
          eprint_line("fatal: bad config line \{line_num} in \{location}")
          @sys.exit(128)
        }
        Some(_) => {
          in_section = true
          continue
        }
      }
    }
    if !in_section {
      // Line outside any section — syntax error
      eprint_line("fatal: bad config line \{line_num} in \{location}")
      @sys.exit(128)
    }
    // Check for unclosed quotes in value
    let eq_idx = trimmed.find("=")
    match eq_idx {
      None => {
        // Bare key without = — could be value-less boolean key
        // git allows value-less keys, but not keys with garbage after them
        let kpart = trim_chars(trimmed, " \t")
        // Valid key: only alphanumeric + '-'
        let mut valid_key = true
        for c in kpart {
          if !((c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '-') {
            valid_key = false
            break
          }
        }
        if !valid_key {
          eprint_line("fatal: bad config line \{line_num} in \{location}")
          @sys.exit(128)
        }
      }
      Some(ei) => {
        // Check for unclosed double quotes in value part
        let val_part = String::unsafe_substring(
          trimmed,
          start=ei + 1,
          end=trimmed.length(),
        )
        let mut in_quote = false
        let mut escaped = false
        for c in val_part {
          if escaped {
            escaped = false
            continue
          }
          if c == '\\' {
            escaped = true
            continue
          }
          if c == '"' {
            in_quote = !in_quote
          }
          // Check for unquoted comment — stop scanning
          if !in_quote && (c == '#' || c == ';') {
            break
          }
        }
        // Check if continuation line (escaped newline at end)
        if in_quote && !escaped && !val_part.has_suffix("\\") {
          // Unclosed quote without continuation
          eprint_line("fatal: bad config line \{line_num} in \{location}")
          @sys.exit(128)
        }
      }
    }
  }
}

///|
/// Remove empty sections matching (section, subsection) from config lines.
/// Only removes sections that match the given section/subsection.
/// A section is "empty" if it has no key-value lines.
/// If the section has comment lines inside, keep the header.
fn remove_empty_sections(
  lines : Array[String],
  section : String,
  subsection : String?,
) -> Array[String] {
  // Pass 1: identify section ranges
  // (header_idx, matches_target, has_keys, has_comments_inside)
  let section_ranges : Array[(Int, Bool, Bool, Bool)] = []
  let mut current_header_idx = -1
  let mut current_matches = false
  let mut has_keys = false
  let mut has_comments = false
  for i, line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, _, _)) => {
        if current_header_idx >= 0 {
          section_ranges.push(
            (current_header_idx, current_matches, has_keys, has_comments),
          )
        }
        current_header_idx = i
        current_matches = section_header_matches(hs, hsub, section, subsection)
        // Check for inline content after header
        match trimmed.find("]") {
          Some(ci) => {
            let after = trim_chars(
              String::unsafe_substring(
                trimmed,
                start=ci + 1,
                end=trimmed.length(),
              ),
              " \t",
            )
            has_keys = after.length() > 0 &&
              !(after[0] == '#') &&
              !(after[0] == ';')
          }
          None => has_keys = false
        }
        has_comments = false
        continue
      }
      None => ()
    }
    if current_header_idx >= 0 {
      if trimmed.length() == 0 {
        continue
      }
      if trimmed[0] == '#' || trimmed[0] == ';' {
        has_comments = true
      } else {
        has_keys = true
      }
    }
  }
  if current_header_idx >= 0 {
    section_ranges.push(
      (current_header_idx, current_matches, has_keys, has_comments),
    )
  }
  // Collect indices of empty matching section headers
  let remove_headers : Array[Int] = []
  for range in section_ranges {
    let (idx, matches, keys, comments) = range
    if matches && !keys && !comments {
      // Don't remove if a preceding comment (not part of continuation) exists
      // before the section header. Scan backwards skipping blank lines.
      let mut skip_section = false
      let mut j = idx - 1
      while j >= 0 {
        let prev = trim_string(lines[j])
        if prev.length() == 0 {
          j -= 1
          continue
        }
        if prev[0] == '#' || prev[0] == ';' {
          // Check if this is part of a continuation line
          // by scanning further back for a line ending with '\'
          let mut is_continuation = false
          if j > 0 {
            let before = lines[j - 1]
            if before.has_suffix("\\") {
              is_continuation = true
            }
          }
          if !is_continuation {
            skip_section = true
          }
        }
        break
      }
      if skip_section {
        continue
      }
      remove_headers.push(idx)
    }
  }
  if remove_headers.length() == 0 {
    return lines
  }
  let remove_set : Array[Bool] = Array::make(lines.length(), false)
  for hi in remove_headers {
    remove_set[hi] = true
    // Remove blank and comment lines after header until next section/key
    let mut j = hi + 1
    while j < lines.length() {
      let t = trim_string(lines[j])
      if t.length() == 0 || t[0] == '#' || t[0] == ';' {
        remove_set[j] = true
        j += 1
        continue
      }
      break
    }
    // Remove preceding blank line
    if hi > 0 && trim_string(lines[hi - 1]).length() == 0 {
      remove_set[hi - 1] = true
    }
  }
  let result : Array[String] = []
  for i, line in lines {
    if !remove_set[i] {
      result.push(line)
    }
  }
  result
}

///|
fn reconstruct_section_header(section : String, subsection : String?) -> String {
  match subsection {
    Some(sub) => "[\{section} \"\{sub}\"]"
    None => "[\{section}]"
  }
}

///|
/// Compare section header against query for KEY matching (replacement).
/// Section name is case-insensitive, subsection is case-sensitive (exact match).
fn section_header_matches(
  header_section : String,
  header_subsection : String?,
  query_section : String,
  query_subsection : String?,
) -> Bool {
  if header_section.to_lower() != query_section.to_lower() {
    return false
  }
  match (header_subsection, query_subsection) {
    (None, None) => true
    (Some(hs), Some(qs)) => hs == qs
    _ => false
  }
}

///|
/// Compare section header against query for SECTION matching (finding section
/// to insert under). For dot-form headers, uses case-insensitive matching for
/// the subsection. For quoted headers, uses case-sensitive subsection matching.
fn section_matches_for_insert(
  header_section : String,
  header_subsection : String?,
  query_section : String,
  query_subsection : String?,
  is_dot_form : Bool,
) -> Bool {
  @config_parse.section_matches_for_insert(
    header_section, header_subsection, query_section, query_subsection, is_dot_form,
  )
}

///|
/// Parse a config key like "section.key" or "section.subsection.key".
/// Returns (section, subsection?, key_name) or None.
/// Validates that the key name starts with an alphabetic character (git compat).
fn parse_config_key(key : String) -> (String, String?, String)? {
  @config_parse.parse_config_key(key)
}

///|
fn find_config_key_line_from_content(content : String, key : String) -> Int? {
  @config_parse.find_config_key_line_from_content(content, key)
}

///|
/// Join continuation lines while keeping their original starting line number.
fn preprocess_config_lines_with_line_numbers(
  raw_lines : Array[String],
) -> Array[(String, Int)] {
  let result : Array[(String, Int)] = []
  let mut i = 0
  while i < raw_lines.length() {
    let mut line = raw_lines[i]
    let start_line = i + 1
    while ends_with_unescaped_backslash(line) &&
          is_continuation_context(line) &&
          i + 1 < raw_lines.length() {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
      i += 1
      line = line + raw_lines[i]
    }
    result.push((line, start_line))
    i += 1
  }
  result
}

///|
/// Check if a line's trailing backslash is in a value context (not a comment).
fn is_continuation_context(line : String) -> Bool {
  let trimmed = trim_string(line)
  // Pure comment lines are never continuation
  if trimmed.length() > 0 && (trimmed[0] == '#' || trimmed[0] == ';') {
    return false
  }
  // For key=value lines, check if the backslash is inside the value
  // (not inside an inline comment)
  let eq_idx = line.find("=")
  match eq_idx {
    None => true // No = sign, treat as potential continuation
    Some(ei) => {
      // Check the value portion after = for unquoted comment start
      let after_eq = String::unsafe_substring(
        line,
        start=ei + 1,
        end=line.length(),
      )
      !has_unquoted_comment_before_backslash(after_eq)
    }
  }
}

///|
/// Check if the value portion has an unquoted comment (# or ;) that
/// appears before the trailing backslash.
fn has_unquoted_comment_before_backslash(value : String) -> Bool {
  let mut in_quote = false
  let mut last_comment_pos = -1
  for i, c in value {
    if c == '"' {
      // Check if it's escaped
      let escaped = if i > 0 { value[i - 1] == '\\' } else { false }
      if !escaped {
        in_quote = !in_quote
      }
    } else if !in_quote && (c == '#' || c == ';') {
      last_comment_pos = i
      break
    }
  }
  last_comment_pos >= 0
}

///|
fn ends_with_unescaped_backslash(s : String) -> Bool {
  let len = s.length()
  if len == 0 {
    return false
  }
  if s[len - 1] != '\\' {
    return false
  }
  // Count trailing backslashes - odd count means continuation
  let mut count = 0
  let mut idx = len - 1
  while idx >= 0 && s[idx] == '\\' {
    count += 1
    if idx == 0 {
      break
    }
    idx -= 1
  }
  count % 2 == 1
}

///|
fn config_lines_from_content(content : String) -> Array[String] {
  @config_parse.config_lines_from_content(content)
}

///|
async fn list_config(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  name_only : Bool,
  null_terminator : Bool,
  scope? : String = "",
  origin? : String = "",
) -> Unit raise Error {
  if !fs.is_file(config_path) {
    return
  }
  let content = decode_bytes(fs.read_file(config_path))
  list_config_from_content(content, name_only, null_terminator, scope~, origin~)
}

///|
async fn list_config_from_content(
  content : String,
  name_only : Bool,
  null_terminator : Bool,
  scope? : String = "",
  origin? : String = "",
) -> Unit raise Error {
  let lines = config_lines_from_content(content)
  let mut current_section = ""
  let mut current_subsection : String? = None
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.length() == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
      continue
    }
    match parse_section_header_line(trimmed) {
      Some((sec, sub, rest, _dot_form)) => {
        current_section = sec.to_lower()
        current_subsection = sub
        // Handle inline key-value after section header
        if rest.length() > 0 && !(rest[0] == '#') && !(rest[0] == ';') {
          let eq_idx = rest.find("=")
          match eq_idx {
            Some(ei) => {
              let key_part = trim_chars(
                String::unsafe_substring(rest, start=0, end=ei),
                " \t",
              ).to_lower()
              let val_part = parse_config_value(
                String::unsafe_substring(rest, start=ei + 1, end=rest.length()),
              )
              let full_key = match current_subsection {
                Some(s) => current_section + "." + s + "." + key_part
                None => current_section + "." + key_part
              }
              print_config_list_entry(
                full_key,
                val_part,
                name_only,
                null_terminator,
                scope~,
                origin~,
              )
            }
            None => {
              // Value-less key after section header
              let key_part = trim_chars(rest, " \t").to_lower()
              if key_part.length() > 0 {
                let full_key = match current_subsection {
                  Some(s) => current_section + "." + s + "." + key_part
                  None => current_section + "." + key_part
                }
                print_config_list_entry(
                  full_key,
                  config_novalue(),
                  name_only,
                  null_terminator,
                  scope~,
                  origin~,
                )
              }
            }
          }
        }
      }
      None => {
        // Parse key=value or value-less key
        let eq_idx = trimmed.find("=")
        match eq_idx {
          Some(i) => {
            let key_part = trim_chars(
              String::unsafe_substring(trimmed, start=0, end=i),
              " \t",
            ).to_lower()
            let val_part = parse_config_value(
              String::unsafe_substring(
                trimmed,
                start=i + 1,
                end=trimmed.length(),
              ),
            )
            let full_key = match current_subsection {
              Some(s) => current_section + "." + s + "." + key_part
              None => current_section + "." + key_part
            }
            print_config_list_entry(
              full_key,
              val_part,
              name_only,
              null_terminator,
              scope~,
              origin~,
            )
          }
          None => {
            // Value-less key (no = sign)
            let key_part = trim_chars(trimmed, " \t").to_lower()
            if key_part.length() > 0 &&
              !(key_part[0] == '#') &&
              !(key_part[0] == ';') {
              let full_key = match current_subsection {
                Some(s) => current_section + "." + s + "." + key_part
                None => current_section + "." + key_part
              }
              print_config_list_entry(
                full_key,
                config_novalue(),
                name_only,
                null_terminator,
                scope~,
                origin~,
              )
            }
          }
        }
      }
    }
  }
}

///|
async fn print_config_list_entry(
  full_key : String,
  value : String,
  name_only : Bool,
  null_terminator : Bool,
  scope? : String = "",
  origin? : String = "",
) -> Unit {
  let prefix = if origin.length() > 0 {
    origin + "\t" + (if scope.length() > 0 { scope + "\t" } else { "" })
  } else if scope.length() > 0 {
    scope + "\t"
  } else {
    ""
  }
  if name_only {
    if null_terminator {
      print_nul_terminated(prefix + full_key)
    } else {
      print_line(prefix + full_key)
    }
  } else if is_config_novalue(value) {
    if null_terminator {
      print_nul_terminated(prefix + full_key)
    } else {
      print_line(prefix + full_key)
    }
  } else if null_terminator {
    print_nul_terminated(prefix + full_key + "\n" + value)
  } else {
    print_line(prefix + full_key + "=" + value)
  }
}

///|
fn get_config_value(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  key : String,
  value_pattern : String?,
  fixed_value : Bool,
) -> String? raise Error {
  if !fs.is_file(config_path) {
    return None
  }
  let raw_content = decode_bytes(fs.read_file(config_path))
  let content = expand_config_includes(fs, config_path, raw_content)
  get_config_value_from_content(content, key, value_pattern, fixed_value)
}

///|
fn get_config_value_from_content(
  content : String,
  key : String,
  value_pattern : String?,
  fixed_value : Bool,
) -> String? {
  @config_parse.get_config_value_from_content(
    content, key, value_pattern, fixed_value,
  )
}

///|
fn get_all_config_values(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  key : String,
  value_pattern : String?,
  fixed_value : Bool,
) -> Array[String] raise Error {
  if !fs.is_file(config_path) {
    return []
  }
  let raw_content = decode_bytes(fs.read_file(config_path))
  let content = expand_config_includes(fs, config_path, raw_content)
  get_all_config_values_from_content(content, key, value_pattern, fixed_value)
}

///|
fn get_all_config_values_from_content(
  content : String,
  key : String,
  value_pattern : String?,
  fixed_value : Bool,
) -> Array[String] {
  @config_parse.get_all_config_values_from_content(
    content, key, value_pattern, fixed_value,
  )
}

///|
fn matches_value_filter(
  val : String,
  pattern : String?,
  fixed_value : Bool,
) -> Bool {
  match pattern {
    None => true
    Some(p) =>
      if fixed_value {
        val == p
      } else {
        config_value_pattern_matches(val, p)
      }
  }
}

///|
fn parse_config_value(raw : String) -> String {
  @config_parse.parse_config_value(raw)
}

///|
/// Format a comment suffix for writing to config file, following git's rules:
/// - If comment starts with whitespace then '#': use as-is
/// - If comment starts with '#': prepend a space
/// - Otherwise: prepend " # "
fn format_comment_suffix(comment : String?) -> String {
  match comment {
    None => ""
    Some(c) => {
      let len = c.length()
      if len == 0 {
        ""
      } else {
        // Count leading blanks
        let mut blanks = 0
        while blanks < len && (c[blanks] == ' ' || c[blanks] == '\t') {
          blanks += 1
        }
        if blanks > 0 && blanks < len && c[blanks] == '#' {
          // Whitespace followed by #: use as-is
          c
        } else if c[0] == '#' {
          // Starts with #: prepend space
          " " + c
        } else {
          // Otherwise: prepend " # "
          " # " + c
        }
      }
    }
  }
}

///|
/// Encode a config value for writing, escaping special characters and
/// quoting when needed (leading/trailing space, #, ;).
fn encode_config_value(value : String) -> String {
  @config_parse.encode_config_value(value)
}

///|
fn format_config_output_value(
  val : String,
  get_bool : Bool,
  get_int : Bool,
  get_bool_or_int : Bool,
  get_path : Bool,
  get_expiry_date : Bool,
  get_color : Bool,
  key : String?,
  source_name : String?,
  line_hint : Int?,
) -> String raise Error {
  // Value-less keys: --bool and --bool-or-int return "true"
  if is_config_novalue(val) {
    if get_bool || get_bool_or_int {
      return "true"
    }
    if get_path {
      let mut msg = "bad pathname config value ''"
      match key {
        Some(k) => msg = msg + " for '\{k}'"
        None => ()
      }
      match source_name {
        Some(src) => {
          msg = msg + " in file \{format_config_source_name(src)}"
          match line_hint {
            Some(line) => msg = msg + " line \{line}"
            None => ()
          }
        }
        None => ()
      }
      raise @bitcore.GitError::InvalidObject(msg)
    }
    return ""
  }
  if get_bool {
    match parse_bool_value(val) {
      Some(b) => if b { "true" } else { "false" }
      None => {
        let mut msg = "bad boolean config value '\{val}'"
        match key {
          Some(k) => msg = msg + " for '\{k}'"
          None => ()
        }
        raise @bitcore.GitError::InvalidObject(msg)
      }
    }
  } else if get_bool_or_int {
    match parse_bool_keyword_value(val) {
      Some(b) => if b { "true" } else { "false" }
      None =>
        match @config_parse.config_parse_size_value(val) {
          Some(n) => n.to_string()
          None =>
            raise @bitcore.GitError::InvalidObject(
              "bad numeric or boolean config value '\{val}'",
            )
        }
    }
  } else if get_path {
    if val.has_prefix("~/") {
      match @sys.get_env_var("HOME") {
        Some(home) =>
          if home.length() == 0 {
            raise @bitcore.GitError::InvalidObject(
              "failed to expand user dir in: '\{val}'",
            )
          } else {
            let rest = String::unsafe_substring(val, start=2, end=val.length())
            if home.has_suffix("/") {
              home + rest
            } else {
              home + "/" + rest
            }
          }
        None =>
          raise @bitcore.GitError::InvalidObject(
            "failed to expand user dir in: '\{val}'",
          )
      }
    } else {
      val
    }
  } else if get_expiry_date {
    let trimmed = val.trim().to_owned()
    let normalized = trimmed.to_lower()
    if normalized == "never" || normalized == "false" {
      "0"
    } else if normalized == "now" || normalized == "all" {
      // git maps "now"/"all" to TIME_MAX so that everything is treated as
      // expired; mirror its decimal representation of UINT64_MAX.
      "18446744073709551615"
    } else {
      match @date_parse.parse_approxidate(trimmed, get_current_timestamp()) {
        Some(ts) => ts.to_string()
        None => {
          let key_for_error = match key {
            Some(k) => k
            None => ""
          }
          raise @bitcore.GitError::InvalidObject(
            "'\{val}' for '\{key_for_error}' is not a valid timestamp",
          )
        }
      }
    }
  } else if get_color {
    match parse_config_color(val) {
      Some(ansi) => ansi
      None =>
        raise @bitcore.GitError::InvalidObject("cannot parse color '\{val}'")
    }
  } else if get_int {
    let (parsed, reason) = parse_config_int_value(val)
    match parsed {
      Some(n) => n.to_string()
      None => {
        let mut msg = "bad numeric config value '\{val}'"
        match key {
          Some(k) => msg = msg + " for '\{k}'"
          None => ()
        }
        match source_name {
          Some(src) => msg = msg + " in file \{format_config_source_name(src)}"
          None => ()
        }
        match reason {
          Some(r) => msg = msg + ": \{r}"
          None => ()
        }
        raise @bitcore.GitError::InvalidObject(msg)
      }
    }
  } else {
    val
  }
}

///|
fn parse_bool_keyword_value(value : String) -> Bool? {
  @config_parse.parse_bool_keyword_value(value)
}

///|
fn parse_config_int_value(val : String) -> (Int64?, String?) {
  @config_parse.parse_config_int_value(val)
}

///|
fn format_config_source_name(source_name : String) -> String {
  if source_name == "standard input" {
    return source_name
  }
  if source_name.has_suffix("/.git/config") {
    return ".git/config"
  }
  let mut slash_idx = -1
  for i, c in source_name {
    if c == '/' {
      slash_idx = i
    }
  }
  if slash_idx >= 0 {
    String::unsafe_substring(
      source_name,
      start=slash_idx + 1,
      end=source_name.length(),
    )
  } else {
    source_name
  }
}

///|
fn parse_config_color(value : String) -> String? {
  let trimmed = value.trim().to_owned().to_lower()
  let code = match trimmed {
    "black" => "30"
    "red" => "31"
    "green" => "32"
    "yellow" => "33"
    "blue" => "34"
    "magenta" => "35"
    "cyan" => "36"
    "white" => "37"
    "normal" | "reset" => "0"
    _ => return None
  }
  Some("\u001b[\{code}m")
}

///|
fn resolve_real_git_for_config() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) =>
      if path.length() > 0 {
        path
      } else {
        @sys.get_env_var("GIT_SHIM_REAL_GIT").unwrap_or("/usr/bin/git")
      }
    None => @sys.get_env_var("GIT_SHIM_REAL_GIT").unwrap_or("/usr/bin/git")
  }
}

///|
async fn delegate_config_to_real_git(args : Array[String]) -> Unit {
  if git_fallback_disabled() {
    exit_no_git_fallback("git config")
  }
  let real_git = resolve_real_git_for_config()
  let argv : Array[String] = ["config"]
  for arg in args {
    argv.push(arg)
  }
  let code = @process.run(
    real_git,
    argv,
    inherit_env=true,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  @sys.exit(code)
}

///|
fn format_bool_for_write(v : String) -> String raise Error {
  match parse_bool_value(v) {
    Some(b) => if b { "true" } else { "false" }
    None =>
      raise @bitcore.GitError::InvalidObject("bad boolean config value '\{v}'")
  }
}

///|
fn format_int_for_write(v : String) -> String raise Error {
  match @config_parse.config_parse_size_value(v) {
    Some(n) => n.to_string()
    None =>
      raise @bitcore.GitError::InvalidObject("bad numeric config value '\{v}'")
  }
}

///|
fn format_bool_or_int_for_write(v : String) -> String raise Error {
  match parse_bool_keyword_value(v) {
    Some(b) => if b { "true" } else { "false" }
    None =>
      match @config_parse.config_parse_size_value(v) {
        Some(n) => n.to_string()
        None =>
          raise @bitcore.GitError::InvalidObject(
            "bad numeric or boolean config value '\{v}'",
          )
      }
  }
}

///|
fn format_color_for_write(v : String) -> String raise Error {
  match parse_config_color(v) {
    Some(_) => v
    None => raise @bitcore.GitError::InvalidObject("cannot parse color '\{v}'")
  }
}

///|
/// Simple regex engine for config value patterns and --get-regexp.
/// Supports: . * + ? ^ $ [...] [^...] \ escape
fn config_regex_matches(text : String, pattern : String) -> Bool {
  let tc = text.to_array()
  let pc = pattern.to_array()
  if pc.length() == 0 {
    return true
  }
  let anchored_start = pc[0] == '^'
  let pi_start = if anchored_start { 1 } else { 0 }
  if anchored_start {
    return regex_match_here(tc, 0, pc, pi_start)
  }
  let mut i = 0
  while i <= tc.length() {
    if regex_match_here(tc, i, pc, pi_start) {
      return true
    }
    i += 1
  }
  false
}

///|
fn regex_match_here(
  tc : Array[Char],
  ti : Int,
  pc : Array[Char],
  pi : Int,
) -> Bool {
  if pi >= pc.length() {
    return true
  }
  // $ anchor at end of pattern
  if pc[pi] == '$' && pi + 1 >= pc.length() {
    return ti >= tc.length()
  }
  // Get atom end position
  let atom_end = regex_atom_end(pc, pi)
  // Check for quantifier after atom
  if atom_end < pc.length() {
    let q = pc[atom_end]
    if q == '*' {
      return regex_match_star(tc, ti, pc, pi, atom_end, atom_end + 1)
    }
    if q == '+' {
      // Must match at least once
      if ti < tc.length() && regex_atom_matches_char(pc, pi, tc[ti]) {
        return regex_match_star(tc, ti + 1, pc, pi, atom_end, atom_end + 1)
      }
      return false
    }
    if q == '?' {
      // Try with and without match
      if ti < tc.length() && regex_atom_matches_char(pc, pi, tc[ti]) {
        if regex_match_here(tc, ti + 1, pc, atom_end + 1) {
          return true
        }
      }
      return regex_match_here(tc, ti, pc, atom_end + 1)
    }
  }
  // No quantifier - must match exactly once
  if ti < tc.length() && regex_atom_matches_char(pc, pi, tc[ti]) {
    return regex_match_here(tc, ti + 1, pc, atom_end)
  }
  false
}

///|
fn regex_match_star(
  tc : Array[Char],
  ti : Int,
  pc : Array[Char],
  atom_pi : Int,
  _atom_end : Int,
  rest_pi : Int,
) -> Bool {
  // Greedy: match as many as possible, then backtrack
  let mut max_ti = ti
  while max_ti < tc.length() && regex_atom_matches_char(pc, atom_pi, tc[max_ti]) {
    max_ti += 1
  }
  let mut t = max_ti
  while t >= ti {
    if regex_match_here(tc, t, pc, rest_pi) {
      return true
    }
    t -= 1
  }
  false
}

///|
/// Returns the end position (exclusive) of the atom starting at pi.
fn regex_atom_end(pc : Array[Char], pi : Int) -> Int {
  if pc[pi] == '\\' && pi + 1 < pc.length() {
    pi + 2
  } else if pc[pi] == '[' {
    let mut i = pi + 1
    if i < pc.length() && pc[i] == '^' {
      i += 1
    }
    // ] right after [ or [^ is literal
    if i < pc.length() && pc[i] == ']' {
      i += 1
    }
    while i < pc.length() && pc[i] != ']' {
      i += 1
    }
    if i < pc.length() {
      i + 1
    } else {
      pc.length()
    }
  } else {
    pi + 1
  }
}

///|
fn regex_atom_matches_char(pc : Array[Char], pi : Int, c : Char) -> Bool {
  if pc[pi] == '.' {
    true
  } else if pc[pi] == '\\' && pi + 1 < pc.length() {
    c == pc[pi + 1]
  } else if pc[pi] == '[' {
    regex_char_class_matches(pc, pi, c)
  } else {
    c == pc[pi]
  }
}

///|
fn regex_char_class_matches(pc : Array[Char], pi : Int, c : Char) -> Bool {
  let mut i = pi + 1
  let negate = i < pc.length() && pc[i] == '^'
  if negate {
    i += 1
  }
  let class_start = i
  let mut matched = false
  while i < pc.length() {
    // ] is literal only at first position after [ or [^
    if pc[i] == ']' && i > class_start {
      break
    }
    // Range: a-z
    if i + 2 < pc.length() && pc[i + 1] == '-' && pc[i + 2] != ']' {
      if c >= pc[i] && c <= pc[i + 2] {
        matched = true
      }
      i += 3
      continue
    }
    if c == pc[i] {
      matched = true
    }
    i += 1
  }
  if negate {
    !matched
  } else {
    matched
  }
}

///|
/// Match a value against a pattern, supporting ! prefix for negation.
fn config_value_pattern_matches(text : String, pattern : String) -> Bool {
  let negate = pattern.length() > 0 && pattern[0] == '!'
  let actual = if negate {
    String::unsafe_substring(pattern, start=1, end=pattern.length())
  } else {
    pattern
  }
  let result = config_regex_matches(text, actual)
  if negate {
    !result
  } else {
    result
  }
}

///|
fn set_config(
  fs : OsFs,
  config_path : String,
  key : String,
  value : String,
  add_mode : Bool,
  comment : String?,
  value_pattern : String?,
) -> Unit raise Error {
  set_config_with_fixed_value(
    fs, config_path, key, value, add_mode, comment, value_pattern, false,
  )
}

///|
fn set_config_with_fixed_value(
  fs : OsFs,
  config_path : String,
  key : String,
  value : String,
  add_mode : Bool,
  comment : String?,
  value_pattern : String?,
  fixed_value : Bool,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  guard parse_config_key(key) is Some((section, subsection, name)) else {
    raise @bitcore.GitError::InvalidObject("invalid key: \{key}")
  }
  let name_l = name.to_lower()
  // git preserves original section case when creating new headers
  let section_header = match subsection {
    Some(sub) => "[\{section} \"\{sub}\"]"
    None => "[\{section}]"
  }
  let encoded_value = encode_config_value(value)
  let comment_suffix = format_comment_suffix(comment)
  if !rfs.is_file(config_path) {
    // Create new config file
    wfs.write_string(
      config_path,
      ensure_trailing_newline(
        section_header +
        "\n\t" +
        name +
        " = " +
        encoded_value +
        comment_suffix +
        "\n",
      ),
    )
    return
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines = split_config_lines_preserve_cr(content)
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  // When value_pattern is present, use multivar behavior
  if value_pattern is Some(vp) {
    // Count matching entries
    let mut match_count = 0
    let mut in_sec = false
    for line in lines {
      let trimmed = trim_string(line)
      match parse_section_header_line(trimmed) {
        Some((hs, hsub, rest, _)) => {
          in_sec = section_header_matches(hs, hsub, section, subsection)
          if in_sec && rest.length() > 0 {
            let inline_eq_idx = rest.find("=")
            match inline_eq_idx {
              Some(idx) => {
                let inline_key = trim_chars(
                  String::unsafe_substring(rest, start=0, end=idx),
                  " \t",
                )
                if inline_key.to_lower() == name_l {
                  let inline_val = parse_config_value(
                    String::unsafe_substring(
                      rest,
                      start=idx + 1,
                      end=rest.length(),
                    ),
                  )
                  if matches_value_filter(inline_val, Some(vp), fixed_value) {
                    match_count += 1
                  }
                }
              }
              None => {
                let inline_key = trim_chars(rest, " \t")
                if inline_key.to_lower() == name_l {
                  if matches_value_filter("", Some(vp), fixed_value) {
                    match_count += 1
                  }
                }
              }
            }
          }
        }
        None =>
          if in_sec {
            let eq_idx = trimmed.find("=")
            match eq_idx {
              Some(idx) => {
                let kp = trim_chars(
                  String::unsafe_substring(trimmed, start=0, end=idx),
                  " \t",
                )
                if kp.to_lower() == name_l {
                  let val = parse_config_value(
                    String::unsafe_substring(
                      trimmed,
                      start=idx + 1,
                      end=trimmed.length(),
                    ),
                  )
                  if matches_value_filter(val, Some(vp), fixed_value) {
                    match_count += 1
                  }
                }
              }
              None => {
                let key_part = trim_chars(trimmed, " \t")
                if key_part.to_lower() == name_l {
                  if matches_value_filter("", Some(vp), fixed_value) {
                    match_count += 1
                  }
                }
              }
            }
          }
      }
    }
    if match_count > 1 {
      raise @bitcore.GitError::InvalidObject(
        "the key \{key} has multiple values",
      )
    }
    if match_count == 0 {
      // No match: add as new entry (like --add)
      set_config_with_fixed_value(
        fs,
        config_path,
        key,
        value,
        true,
        comment,
        None,
        false,
      )
      return
    }
    // Exactly 1 match: replace it
    let mut in_sec2 = false
    let mut replaced = false
    let result : Array[String] = []
    for line in lines {
      let trimmed = trim_string(line)
      match parse_section_header_line(trimmed) {
        Some((hs, hsub, rest, _)) => {
          in_sec2 = section_header_matches(hs, hsub, section, subsection)
          if in_sec2 && !replaced && rest.length() > 0 {
            let inline_eq_idx = rest.find("=")
            let mut inline_match = false
            match inline_eq_idx {
              Some(idx) => {
                let inline_key = trim_chars(
                  String::unsafe_substring(rest, start=0, end=idx),
                  " \t",
                )
                if inline_key.to_lower() == name_l {
                  let inline_val = parse_config_value(
                    String::unsafe_substring(
                      rest,
                      start=idx + 1,
                      end=rest.length(),
                    ),
                  )
                  inline_match = matches_value_filter(
                    inline_val,
                    Some(vp),
                    fixed_value,
                  )
                }
              }
              None => {
                let inline_key = trim_chars(rest, " \t")
                if inline_key.to_lower() == name_l {
                  inline_match = matches_value_filter("", Some(vp), fixed_value)
                }
              }
            }
            if inline_match {
              result.push(reconstruct_section_header(hs, hsub))
              result.push("\t" + name + " = " + encoded_value + comment_suffix)
              replaced = true
              continue
            }
          }
          result.push(line)
        }
        None => {
          if in_sec2 && !replaced {
            let eq_idx = trimmed.find("=")
            match eq_idx {
              Some(idx) => {
                let kp = trim_chars(
                  String::unsafe_substring(trimmed, start=0, end=idx),
                  " \t",
                )
                if kp.to_lower() == name_l {
                  let val = parse_config_value(
                    String::unsafe_substring(
                      trimmed,
                      start=idx + 1,
                      end=trimmed.length(),
                    ),
                  )
                  if matches_value_filter(val, Some(vp), fixed_value) {
                    result.push(
                      "\t" + name + " = " + encoded_value + comment_suffix,
                    )
                    replaced = true
                    continue
                  }
                }
              }
              None => {
                let key_part = trim_chars(trimmed, " \t")
                if key_part.to_lower() == name_l {
                  if matches_value_filter("", Some(vp), fixed_value) {
                    result.push(
                      "\t" + name + " = " + encoded_value + comment_suffix,
                    )
                    replaced = true
                    continue
                  }
                }
              }
            }
          }
          result.push(line)
        }
      }
    }
    wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
    return
  }
  let mut in_section = false
  let mut in_section_for_insert = false
  let mut found = false
  let mut section_end = -1
  let result : Array[String] = []
  for i, line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, rest, dot_form)) => {
        if in_section && !found {
          // Insert at end of previous section
          result.push("\t" + name + " = " + encoded_value + comment_suffix)
          found = true
        }
        in_section = section_header_matches(hs, hsub, section, subsection)
        in_section_for_insert = section_matches_for_insert(
          hs, hsub, section, subsection, dot_form,
        )
        if in_section_for_insert {
          section_end = i
        }
        // Handle inline key-value after section header: [section] key = value
        if in_section && rest.length() > 0 && !add_mode {
          let rest_eq = rest.find("=")
          match rest_eq {
            Some(rei) => {
              let inline_key = trim_chars(
                String::unsafe_substring(rest, start=0, end=rei),
                " \t",
              )
              if inline_key.to_lower() == name_l {
                // Strip inline entry from header line
                let header_only = reconstruct_section_header(hs, hsub)
                result.push(header_only)
                result.push(
                  "\t" + name + " = " + encoded_value + comment_suffix,
                )
                found = true
                continue
              }
            }
            None => ()
          }
        }
        result.push(line)
      }
      None => {
        if in_section && !add_mode {
          let eq_idx = trimmed.find("=")
          match eq_idx {
            Some(idx) => {
              let key_part = trim_chars(
                String::unsafe_substring(trimmed, start=0, end=idx),
                " \t",
              )
              if key_part.to_lower() == name_l {
                result.push(
                  "\t" + name + " = " + encoded_value + comment_suffix,
                )
                found = true
                continue
              }
            }
            None => ()
          }
        }
        if in_section_for_insert && trimmed.length() > 0 {
          section_end = i
        }
        result.push(line)
      }
    }
  }
  if !found {
    if in_section || in_section_for_insert {
      // In matching section at end of file, append here
      result.push("\t" + name + " = " + encoded_value + comment_suffix)
      found = true
    } else if section_end >= 0 {
      // Insert after section header
      let new_result : Array[String] = []
      for i, line in result {
        new_result.push(line)
        if i == section_end && !found {
          new_result.push("\t" + name + " = " + encoded_value + comment_suffix)
          found = true
        }
      }
      wfs.write_string(
        config_path,
        ensure_trailing_newline(new_result.join("\n")),
      )
      return
    }
    if !found {
      // Add new section at end
      result.push(section_header)
      result.push("\t" + name + " = " + encoded_value + comment_suffix)
    }
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn unset_config(
  fs : OsFs,
  config_path : String,
  key : String,
  value_pattern : String?,
  fixed_value : Bool,
  unset_all : Bool,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  if !rfs.is_file(config_path) {
    return
  }
  guard parse_config_key(key) is Some((section, subsection, name)) else {
    return
  }
  let name_l = name.to_lower()
  let content = decode_bytes(rfs.read_file(config_path))
  let lines = split_config_lines_preserve_cr(content)
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  // First pass: count matching entries for ambiguous detection
  if !unset_all && value_pattern is None {
    let match_count = count_config_matches(lines, section, subsection, name_l)
    if match_count > 1 {
      raise @bitcore.GitError::InvalidObject("key '\{key}' has multiple values")
    }
  }
  let mut in_section = false
  let mut removed = false
  let mut skip_continuation = false
  let result : Array[String] = []
  for line in lines {
    // Skip continuation lines from a previously removed entry
    if skip_continuation {
      if line.has_suffix("\\") {
        continue
      }
      skip_continuation = false
      continue
    }
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") {
      let close_idx = trimmed.find("]")
      match close_idx {
        Some(close_i) => {
          let header_content = trim_chars(
            String::unsafe_substring(trimmed, start=1, end=close_i),
            " \t",
          )
          let after_header = trim_chars(
            String::unsafe_substring(
              trimmed,
              start=close_i + 1,
              end=trimmed.length(),
            ),
            " \t",
          )
          let (hs, hsub) = parse_header_content(header_content)
          let section_matches_flag = section_header_matches(
            hs, hsub, section, subsection,
          )
          if after_header.length() > 0 && section_matches_flag {
            in_section = true
            let inline_eq_idx = after_header.find("=")
            let (inline_key, inline_value) = match inline_eq_idx {
              Some(idx) =>
                (
                  trim_chars(
                    String::unsafe_substring(after_header, start=0, end=idx),
                    " \t",
                  ),
                  Some(
                    parse_config_value(
                      String::unsafe_substring(
                        after_header,
                        start=idx + 1,
                        end=after_header.length(),
                      ),
                    ),
                  ),
                )
              None => (after_header, (None : String?))
            }
            if inline_key.to_lower() == name_l {
              let should_remove = match value_pattern {
                Some(vp) =>
                  match inline_value {
                    Some(iv) => matches_value_filter(iv, Some(vp), fixed_value)
                    None => false
                  }
                None => true
              }
              if should_remove {
                if unset_all {
                  continue
                }
                if !removed {
                  removed = true
                  continue
                }
              }
            }
          }
        }
        None => ()
      }
    }
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, _, _)) => {
        in_section = section_header_matches(hs, hsub, section, subsection)
        result.push(line)
        continue
      }
      None => ()
    }
    if in_section {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part.to_lower() == name_l {
            let val = parse_config_value(
              String::unsafe_substring(
                trimmed,
                start=idx + 1,
                end=trimmed.length(),
              ),
            )
            let should_remove = matches_value_filter(
              val, value_pattern, fixed_value,
            )
            if should_remove {
              if unset_all || !removed {
                removed = true
                // Check if line has continuation
                if line.has_suffix("\\") {
                  skip_continuation = true
                }
                continue
              }
            }
          }
        }
        None => {
          let key_only = trim_chars(trimmed, " \t")
          if key_only.to_lower() == name_l && value_pattern is None {
            if unset_all || !removed {
              removed = true
              continue
            }
          }
        }
      }
    }
    result.push(line)
  }
  if !removed {
    @sys.exit(5)
  }
  let cleaned = remove_empty_sections(result, section, subsection)
  wfs.write_string(config_path, ensure_trailing_newline(cleaned.join("\n")))
}

///|
/// Count how many entries match the given key in config lines.
fn count_config_matches(
  lines : Array[String],
  section : String,
  subsection : String?,
  name_l : String,
) -> Int {
  let mut in_section = false
  let mut count = 0
  for line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, _, _)) =>
        in_section = section_header_matches(hs, hsub, section, subsection)
      None =>
        if in_section {
          let eq_idx = trimmed.find("=")
          match eq_idx {
            Some(idx) => {
              let key_part = trim_chars(
                String::unsafe_substring(trimmed, start=0, end=idx),
                " \t",
              )
              if key_part.to_lower() == name_l {
                count += 1
              }
            }
            None => {
              let key_only = trim_chars(trimmed, " \t")
              if key_only.to_lower() == name_l {
                count += 1
              }
            }
          }
        }
    }
  }
  count
}

///|
/// Parse header content (between [ and ]) into section name and subsection.
fn parse_header_content(header_content : String) -> (String, String?) {
  match header_content.find(" ") {
    None => (header_content, None)
    Some(si) => {
      let sec = String::unsafe_substring(header_content, start=0, end=si)
      let raw_sub = trim_chars(
        String::unsafe_substring(
          header_content,
          start=si + 1,
          end=header_content.length(),
        ),
        " \t",
      )
      let sub = if raw_sub.length() >= 2 &&
        raw_sub[0] == '"' &&
        raw_sub[raw_sub.length() - 1] == '"' {
        String::unsafe_substring(raw_sub, start=1, end=raw_sub.length() - 1)
      } else {
        raw_sub
      }
      (sec, Some(sub))
    }
  }
}

///|
fn replace_all_config(
  fs : OsFs,
  config_path : String,
  key : String,
  value : String,
  value_pattern : String?,
  fixed_value : Bool,
  comment : String?,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  guard parse_config_key(key) is Some((section, subsection, name)) else {
    return
  }
  let name_l = name.to_lower()
  let encoded_value = encode_config_value(value)
  let comment_suffix = format_comment_suffix(comment)
  let new_line = "\t" + name + " = " + encoded_value + comment_suffix
  if !rfs.is_file(config_path) {
    let section_header = match subsection {
      Some(sub) => "[\{section} \"\{sub}\"]"
      None => "[\{section}]"
    }
    wfs.write_string(
      config_path,
      ensure_trailing_newline(section_header + "\n" + new_line + "\n"),
    )
    return
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines = split_config_lines_preserve_cr(content)
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  // Pass 1: find the LAST matching line index (git replaces at last match position)
  // Also track inline key-value matches on section headers
  let mut in_section = false
  let mut last_match_idx = -1
  let mut last_match_is_inline = false
  for i, line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, rest, _)) => {
        in_section = section_header_matches(hs, hsub, section, subsection)
        // Check for inline key-value on section header
        if in_section && rest.length() > 0 {
          let rest_eq = rest.find("=")
          match rest_eq {
            Some(rei) => {
              let inline_key = trim_chars(
                String::unsafe_substring(rest, start=0, end=rei),
                " \t",
              )
              if inline_key.to_lower() == name_l {
                let val = parse_config_value(
                  String::unsafe_substring(
                    rest,
                    start=rei + 1,
                    end=rest.length(),
                  ),
                )
                let pm = matches_value_filter(val, value_pattern, fixed_value)
                if pm {
                  last_match_idx = i
                  last_match_is_inline = true
                }
              }
            }
            None => {
              // Value-less inline key
              let inline_key = trim_chars(rest, " \t")
              if inline_key.to_lower() == name_l &&
                matches_value_filter("", value_pattern, fixed_value) {
                last_match_idx = i
                last_match_is_inline = true
              }
            }
          }
        }
      }
      None => ()
    }
    if in_section && parse_section_header_line(trimmed) is None {
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part.to_lower() == name_l {
            let val = parse_config_value(
              String::unsafe_substring(
                trimmed,
                start=idx + 1,
                end=trimmed.length(),
              ),
            )
            let pattern_matches = matches_value_filter(
              val, value_pattern, fixed_value,
            )
            if pattern_matches {
              last_match_idx = i
              last_match_is_inline = false
            }
          }
        }
        None => {
          let key_part = trim_chars(trimmed, " \t")
          if key_part.to_lower() == name_l &&
            matches_value_filter("", value_pattern, fixed_value) {
            last_match_idx = i
            last_match_is_inline = false
          }
        }
      }
    }
  }
  // Pass 2: build result, replacing at last match, removing others
  in_section = false
  let result : Array[String] = []
  if last_match_idx >= 0 {
    for i, line in lines {
      let trimmed = trim_string(line)
      let is_header = parse_section_header_line(trimmed)
      match is_header {
        Some((hs, hsub, _, _)) =>
          in_section = section_header_matches(hs, hsub, section, subsection)
        None => ()
      }
      if i == last_match_idx {
        if last_match_is_inline {
          // Inline match: strip inline entry, output header only + new value
          match is_header {
            Some((hs, hsub, _, _)) => {
              result.push(reconstruct_section_header(hs, hsub))
              result.push(new_line)
            }
            None => result.push(new_line)
          }
        } else {
          result.push(new_line)
        }
        continue
      }
      // Check for inline matches on headers (non-last-match, should be removed)
      if in_section {
        match is_header {
          Some((hs, hsub, rest, _)) =>
            if rest.length() > 0 {
              let rest_eq = rest.find("=")
              let is_inline_match = match rest_eq {
                Some(rei) => {
                  let ik = trim_chars(
                    String::unsafe_substring(rest, start=0, end=rei),
                    " \t",
                  )
                  ik.to_lower() == name_l
                }
                None => {
                  let ik = trim_chars(rest, " \t")
                  ik.to_lower() == name_l
                }
              }
              if is_inline_match {
                // Strip inline entry from this header
                result.push(reconstruct_section_header(hs, hsub))
                continue
              }
            }
          None => ()
        }
      }
      if in_section && is_header is None {
        let eq_idx = trimmed.find("=")
        match eq_idx {
          Some(idx) => {
            let key_part = trim_chars(
              String::unsafe_substring(trimmed, start=0, end=idx),
              " \t",
            )
            if key_part.to_lower() == name_l {
              let val = parse_config_value(
                String::unsafe_substring(
                  trimmed,
                  start=idx + 1,
                  end=trimmed.length(),
                ),
              )
              let pattern_matches = matches_value_filter(
                val, value_pattern, fixed_value,
              )
              if pattern_matches {
                continue // skip earlier matches
              }
            }
          }
          None => {
            let key_part = trim_chars(trimmed, " \t")
            if key_part.to_lower() == name_l &&
              matches_value_filter("", value_pattern, fixed_value) {
              continue
            }
          }
        }
      }
      result.push(line)
    }
  } else {
    // No matches found, add as new entry
    for line in lines {
      result.push(line)
    }
    let section_header = match subsection {
      Some(sub) => "[\{section} \"\{sub}\"]"
      None => "[\{section}]"
    }
    result.push(section_header)
    result.push(new_line)
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
async fn get_regexp_config(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  pattern : String,
  value_pattern : String?,
  fixed_value : Bool,
  get_bool : Bool,
  get_int : Bool,
  name_only : Bool,
  null_terminator : Bool,
  scope? : String = "",
  origin? : String = "",
) -> Bool raise Error {
  if !fs.is_file(config_path) {
    return false
  }
  let raw_content = decode_bytes(fs.read_file(config_path))
  let content = expand_config_includes(fs, config_path, raw_content)
  get_regexp_config_from_content(
    content,
    pattern,
    value_pattern,
    fixed_value,
    get_bool,
    get_int,
    name_only,
    null_terminator,
    config_path,
    scope~,
    origin~,
  )
}

///|
async fn get_regexp_config_from_content(
  content : String,
  pattern : String,
  value_pattern : String?,
  fixed_value : Bool,
  get_bool : Bool,
  get_int : Bool,
  name_only : Bool,
  null_terminator : Bool,
  source_name : String,
  scope? : String = "",
  origin? : String = "",
) -> Bool raise Error {
  let prefix = if origin.length() > 0 {
    origin + "\t" + (if scope.length() > 0 { scope + "\t" } else { "" })
  } else if scope.length() > 0 {
    scope + "\t"
  } else {
    ""
  }
  let lines = config_lines_from_content(content)
  let mut current_section = ""
  let mut current_subsection : String? = None
  let mut found = false
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.length() == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
      continue
    }
    match parse_section_header_line(trimmed) {
      Some((sec, sub, _, _)) => {
        current_section = sec.to_lower()
        current_subsection = sub
      }
      None => {
        let eq_idx = trimmed.find("=")
        let (key_part_opt, val) = match eq_idx {
          Some(i) => {
            let kp = trim_chars(
              String::unsafe_substring(trimmed, start=0, end=i),
              " \t",
            ).to_lower()
            let v = parse_config_value(
              String::unsafe_substring(
                trimmed,
                start=i + 1,
                end=trimmed.length(),
              ),
            )
            (Some(kp), v)
          }
          None => {
            // Value-less key
            let kp = trim_chars(trimmed, " \t").to_lower()
            if kp.length() > 0 && !(kp[0] == '#') && !(kp[0] == ';') {
              (Some(kp), config_novalue())
            } else {
              ((None : String?), "")
            }
          }
        }
        match key_part_opt {
          Some(key_part) => {
            let full_key = match current_subsection {
              Some(sub) => current_section + "." + sub + "." + key_part
              None => current_section + "." + key_part
            }
            let match_val = if is_config_novalue(val) { "" } else { val }
            if config_regex_matches(full_key, pattern) &&
              matches_value_filter(match_val, value_pattern, fixed_value) {
              found = true
              if name_only {
                if null_terminator {
                  print_nul_terminated(prefix + full_key)
                } else {
                  print_line(prefix + full_key)
                }
              } else if is_config_novalue(val) {
                // Value-less key: --bool → "true", else just key name
                if get_bool {
                  if null_terminator {
                    print_nul_terminated(prefix + full_key + "\n" + "true")
                  } else {
                    print_line(prefix + full_key + " true")
                  }
                } else if null_terminator {
                  print_nul_terminated(prefix + full_key)
                } else {
                  print_line(prefix + full_key)
                }
              } else {
                let formatted = format_config_output_value(
                  val,
                  get_bool,
                  get_int,
                  false,
                  false,
                  false,
                  false,
                  Some(full_key),
                  Some(source_name),
                  (None : Int?),
                )
                if null_terminator {
                  print_nul_terminated(prefix + full_key + "\n" + formatted)
                } else {
                  // --get-regexp uses space separator (not =)
                  print_line(prefix + full_key + " " + formatted)
                }
              }
            }
          }
          None => ()
        }
      }
    }
  }
  found
}

///|
fn remove_config_section_file(
  fs : OsFs,
  config_path : String,
  section_key : String,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  if !rfs.is_file(config_path) {
    return
  }
  let parts : Array[String] = []
  for p in section_key.split(".") {
    parts.push(p.to_owned())
  }
  if parts.length() == 0 {
    return
  }
  let (section, subsection) = if parts.length() == 1 {
    (parts[0], (None : String?))
  } else {
    let sub : Array[String] = []
    for i in 1..<parts.length() {
      sub.push(parts[i])
    }
    (parts[0], Some(sub.join(".")))
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines = split_config_lines_preserve_cr(content)
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let mut in_section = false
  let mut found_section = false
  let result : Array[String] = []
  for line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, _, _)) => {
        let matched = section_header_matches(hs, hsub, section, subsection)
        in_section = matched
        if matched {
          found_section = true
          continue
        }
        result.push(line)
      }
      None => if in_section { continue } else { result.push(line) }
    }
  }
  if !found_section {
    raise @bitcore.GitError::InvalidObject("no such section: '\{section_key}'")
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn rename_config_section(
  fs : OsFs,
  config_path : String,
  old_name : String,
  new_name : String,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  if !rfs.is_file(config_path) {
    raise @bitcore.GitError::InvalidObject("no such section: '\{old_name}'")
  }
  // Reject empty names
  if old_name.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "invalid section name: '\{old_name}'",
    )
  }
  if new_name.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "invalid section name: '\{new_name}'",
    )
  }
  // Validate section part of new_name (before first dot)
  let new_sec_parts : Array[String] = []
  for p in new_name.split(".") {
    new_sec_parts.push(p.to_owned())
  }
  let new_sec_name = new_sec_parts[0]
  if !is_valid_section_name(new_sec_name) {
    raise @bitcore.GitError::InvalidObject(
      "invalid section name: '\{new_name}'",
    )
  }
  // Parse old section key
  let old_parts : Array[String] = []
  for p in old_name.split(".") {
    old_parts.push(p.to_owned())
  }
  if old_parts.length() == 0 {
    return
  }
  let (old_section, old_subsection) = if old_parts.length() == 1 {
    (old_parts[0], (None : String?))
  } else {
    let sub : Array[String] = []
    for i in 1..<old_parts.length() {
      sub.push(old_parts[i])
    }
    (old_parts[0], Some(sub.join(".")))
  }
  // Parse new section key
  let new_parts : Array[String] = []
  for p in new_name.split(".") {
    new_parts.push(p.to_owned())
  }
  if new_parts.length() == 0 {
    return
  }
  let new_header = if new_parts.length() == 1 {
    "[\{new_parts[0]}]"
  } else {
    let sub : Array[String] = []
    for i in 1..<new_parts.length() {
      sub.push(new_parts[i])
    }
    let sub_joined = sub.join(".")
    "[\{new_parts[0]} \"\{sub_joined}\"]"
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let lines = split_config_lines_preserve_cr(content)
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let mut slash_idx = -1
  for i, c in config_path {
    if c == '/' {
      slash_idx = i
    }
  }
  let path_for_error = if slash_idx >= 0 {
    String::unsafe_substring(
      config_path,
      start=slash_idx + 1,
      end=config_path.length(),
    )
  } else {
    config_path
  }
  let max_config_line_len = 512 * 1024
  for i, line in lines {
    if line.length() >= max_config_line_len {
      raise @bitcore.GitError::InvalidObject(
        "refusing to work with overly long line in '\{path_for_error}' on line \{i + 1}",
      )
    }
  }
  let mut found = false
  let result : Array[String] = []
  for line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((hs, hsub, rest, _)) =>
        if section_header_matches(hs, hsub, old_section, old_subsection) {
          found = true
          if rest.length() > 0 {
            // Preserve inline content after header: [section] key = value
            result.push(new_header)
            result.push("\t" + rest)
          } else {
            result.push(new_header)
          }
        } else {
          result.push(line)
        }
      None => result.push(line)
    }
  }
  if !found {
    raise @bitcore.GitError::InvalidObject("no such section: '\{old_name}'")
  }
  wfs.write_string(config_path, ensure_trailing_newline(result.join("\n")))
}

///|
fn ensure_trailing_newline(content : String) -> String {
  if content.length() == 0 || content.has_suffix("\n") {
    content
  } else {
    content + "\n"
  }
}

///|
async fn print_nul_terminated(s : String) -> Unit {
  let arr : Array[Byte] = @utf8.encode(s).to_array()
  arr.push(b'\x00')
  @stdio.stdout.write(bytes_from_array(arr))
}

///|
/// Collect all remote.*.url values from config content (no include expansion).
fn collect_remote_urls_from_content(content : String) -> Array[String] {
  let lines = config_lines_from_content(content)
  let urls : Array[String] = []
  let mut in_remote = false
  for line in lines {
    let trimmed = trim_string(line)
    if trimmed.length() == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
      continue
    }
    match parse_section_header_line(trimmed) {
      Some((sec, _sub, _, _)) => in_remote = sec.to_lower() == "remote"
      None =>
        if in_remote {
          let eq_idx = trimmed.find("=")
          match eq_idx {
            Some(idx) => {
              let key_part = trim_chars(
                String::unsafe_substring(trimmed, start=0, end=idx),
                " \t",
              )
              if key_part.to_lower() == "url" {
                let val = parse_config_value(
                  String::unsafe_substring(
                    trimmed,
                    start=idx + 1,
                    end=trimmed.length(),
                  ),
                )
                urls.push(val)
              }
            }
            None => ()
          }
        }
    }
  }
  urls
}

///|
/// Simple glob matching supporting * (single segment) and ** (multi segment).
/// Segments are separated by '/'.
fn glob_match_url(pattern : String, text : String) -> Bool {
  glob_match_impl(pattern, 0, text, 0)
}

///|
fn glob_match_impl(pat : String, pi : Int, text : String, ti : Int) -> Bool {
  let plen = pat.length()
  let tlen = text.length()
  let mut pi = pi
  let mut ti = ti
  while pi < plen {
    if pat[pi] == '*' && pi + 1 < plen && pat[pi + 1] == '*' {
      // ** - match any number of path segments
      pi += 2
      // Skip trailing / after **
      if pi < plen && pat[pi] == '/' {
        pi += 1
      }
      // Try matching rest of pattern at every position
      let mut k = ti
      while k <= tlen {
        if glob_match_impl(pat, pi, text, k) {
          return true
        }
        if k < tlen {
          k += 1
        } else {
          break
        }
      }
      return false
    } else if pat[pi] == '*' {
      // * - match within single segment (no /)
      pi += 1
      let mut k = ti
      while k <= tlen {
        if glob_match_impl(pat, pi, text, k) {
          return true
        }
        if k < tlen && text[k] == '/' {
          break
        }
        if k < tlen {
          k += 1
        } else {
          break
        }
      }
      return false
    } else {
      if ti >= tlen || pat[pi] != text[ti] {
        return false
      }
      pi += 1
      ti += 1
    }
  }
  ti >= tlen
}

///|
/// Expand includeIf.hasconfig:remote.*.url directives in config content.
/// Returns expanded content with included files inserted at the correct position.
fn expand_config_includes(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  content : String,
) -> String raise Error {
  // First pass: collect remote URLs from main config (without expansion)
  let remote_urls = collect_remote_urls_from_content(content)
  // Second pass: process includes
  let lines = config_lines_from_content(content)
  let result : Array[String] = []
  let mut current_section = ""
  let mut include_condition : String? = None // None = no include, Some("") = unconditional, Some(pattern) = hasconfig
  for line in lines {
    let trimmed = trim_string(line)
    match parse_section_header_line(trimmed) {
      Some((sec, sub, _, _)) => {
        let sec_l = sec.to_lower()
        current_section = sec_l
        // Check for include/includeIf
        if sec_l == "include" {
          include_condition = Some("") // unconditional include
        } else if sec_l == "includeif" {
          match sub {
            Some(cond) =>
              if cond.has_prefix("hasconfig:remote.") && cond.contains(".url:") {
                include_condition = Some(cond)
              } else {
                include_condition = None
              }
            None => include_condition = None
          }
        } else {
          include_condition = None
        }
        result.push(line)
        continue
      }
      None => ()
    }
    if include_condition is Some(_) &&
      (current_section == "include" || current_section == "includeif") {
      // Parse path key
      let eq_idx = trimmed.find("=")
      match eq_idx {
        Some(idx) => {
          let key_part = trim_chars(
            String::unsafe_substring(trimmed, start=0, end=idx),
            " \t",
          )
          if key_part.to_lower() == "path" {
            let path_val = parse_config_value(
              String::unsafe_substring(
                trimmed,
                start=idx + 1,
                end=trimmed.length(),
              ),
            )
            // Resolve path relative to config file's directory
            let resolved = if path_val.has_prefix("/") {
              path_val
            } else {
              let dir = parent_dir(config_path)
              if dir == "." || dir == "" {
                path_val
              } else {
                dir + "/" + path_val
              }
            }
            // Check condition
            let should_include = match include_condition {
              Some(cond) =>
                if cond == "" {
                  true // unconditional [include]
                } else {
                  // hasconfig:remote.*.url:PATTERN
                  let url_pattern = match cond.find(".url:") {
                    Some(colon_idx) => string_slice_from(cond, colon_idx + 5)
                    None => ""
                  }
                  if url_pattern.length() > 0 {
                    let mut matched = false
                    for url in remote_urls {
                      if glob_match_url(url_pattern, url) {
                        matched = true
                        break
                      }
                    }
                    matched
                  } else {
                    false
                  }
                }
              None => false
            }
            if should_include && fs.is_file(resolved) {
              let inc_content = decode_bytes(fs.read_file(resolved))
              // Validate: included files from hasconfig cannot contain remote URLs
              match include_condition {
                Some(cond) if cond != "" => {
                  let inc_urls = collect_remote_urls_from_content(inc_content)
                  if inc_urls.length() > 0 {
                    raise @bitcore.GitError::IoError(
                      "fatal: remote URLs cannot be configured in file directly or indirectly included by includeIf.hasconfig:remote.*.url",
                    )
                  }
                }
                _ => ()
              }
              // Insert included content
              let inc_lines = config_lines_from_content(inc_content)
              for inc_line in inc_lines {
                result.push(inc_line)
              }
            }
          }
        }
        None => ()
      }
      result.push(line)
      continue
    }
    result.push(line)
  }
  result.join("\n")
}

///|
