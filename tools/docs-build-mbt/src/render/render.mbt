///| Render a markdown source string to HTML.
///
/// Thin wrapper over `mizchi/markdown`'s convenience `md_to_html`. We keep
/// bare URLs as autolinks (the default) and leave wikilinks off — the docs
/// site uses standard markdown link syntax everywhere.
pub fn render(source : String) -> String {
  @markdown.md_to_html(source)
}
