///| Bootstrap package for native startup fixes.

///|
#cfg(target="native")
extern "C" fn bit_ensure_stdin_open() = "bit_ensure_stdin_open"

///|
#cfg(target="native")
pub fn init_stdin_guard() -> Unit {
  bit_ensure_stdin_open()
}

///|
#cfg(not(target="native"))
pub fn init_stdin_guard() -> Unit {
  ()
}
