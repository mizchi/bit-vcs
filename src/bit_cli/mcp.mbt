///| MCP command handler

///|
fn print_mcp_usage() -> Unit {
  println("Usage: bit mcp [--help]")
  println("")
  println("Start bit MCP server (stdio).")
  println("This command is available on native target only.")
}

///|
fn mcp_has_help_arg(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "help" || arg == "-h" || arg == "--help" {
      return true
    }
  }
  false
}

///|
async fn handle_mcp(args : Array[String]) -> Unit raise Error {
  if mcp_has_help_arg(args) {
    print_mcp_usage()
    return
  }
  for arg in args {
    warn_unimplemented_arg("mcp", arg)
  }
  @mcp.run_mcp_server()
}
