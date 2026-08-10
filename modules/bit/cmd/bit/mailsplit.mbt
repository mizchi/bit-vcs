///| git mailsplit - split mbox file into individual messages

///|
async fn handle_mailsplit(args : Array[String]) -> Unit raise Error {
  let mut output_dir = "."
  let mut keep_from = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-b" => keep_from = true
      "-h" | "--help" => {
        show_simple_command_help(
          "git mailsplit [-o<dir>] [-b] [--] <mbox>...",
          summary="Split mbox file into individual messages.",
        )
        return
      }
      _ if arg.has_prefix("-o") => {
        let dir = arg[2:].to_owned()
        if dir.length() > 0 {
          output_dir = dir
        } else {
          i += 1
          if i < args.length() {
            output_dir = args[i]
          }
        }
      }
      "-d" =>
        // -d<N> number of digits, ignore (we always use 4)
        i += 1
      _ if arg.has_prefix("-d") => () // -d<N> combined form
      "--" => {
        i += 1
        while i < args.length() {
          positional.push(args[i])
          i += 1
        }
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("mailsplit", arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  // Read input: from files or stdin
  let input = if positional.length() > 0 {
    let sb = StringBuilder::new()
    for path in positional {
      let data = @fs.read_file_to_bytes(path) catch {
        err => {
          eprint_line(
            "fatal: cannot open \{path}: \{@debug.render(Repr(err))}",
          )
          @sys.exit(1)
          return
        }
      }
      sb.write_string(decode_bytes(data))
    }
    sb.to_string()
  } else {
    decode_bytes(read_all_stdin())
  }
  // Ensure output dir exists
  ensure_dir(output_dir)
  // Split on "From " lines at start of line
  let lines = mailsplit_split_lines(input)
  let messages : Array[StringBuilder] = []
  let mut current : StringBuilder? = None
  for line in lines {
    if line.has_prefix("From ") {
      // Start a new message
      let msg = StringBuilder::new()
      if keep_from {
        msg.write_string(line)
        msg.write_char('\n')
      }
      messages.push(msg)
      current = Some(msg)
    } else {
      match current {
        Some(msg) => {
          msg.write_string(line)
          msg.write_char('\n')
        }
        None => () // Text before first "From " line is discarded
      }
    }
  }
  // Write each message as a numbered file
  for idx, msg in messages {
    let num = idx + 1
    let filename = mailsplit_format_number(num, 4)
    let path = output_dir + "/" + filename
    let content = msg.to_string()
    @fs.write_string_to_file(path, content) catch {
      err => {
        eprint_line(
          "fatal: cannot write \{path}: \{@debug.render(Repr(err))}",
        )
        @sys.exit(1)
        return
      }
    }
  }
  // Print count to stdout
  print_line(messages.length().to_string())
}

///|
fn mailsplit_split_lines(input : String) -> Array[String] {
  let lines : Array[String] = []
  for line_view in input.split("\n") {
    lines.push(line_view.to_owned())
  }
  // Remove trailing empty string from final newline
  if lines.length() > 0 && lines[lines.length() - 1].length() == 0 {
    ignore(lines.pop())
  }
  lines
}

///|
fn mailsplit_format_number(n : Int, width : Int) -> String {
  let s = n.to_string()
  let pad = width - s.length()
  if pad <= 0 {
    return s
  }
  let sb = StringBuilder::new()
  for _i = 0; _i < pad; _i = _i + 1 {
    sb.write_char('0')
  }
  sb.write_string(s)
  sb.to_string()
}
