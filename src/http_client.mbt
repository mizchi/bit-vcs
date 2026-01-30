///| HTTP client abstraction for cross-platform support

///| Similar to FileSystem/RepoFileSystem traits

///|
pub struct HttpResponse {
  code : Int
  headers : Map[String, String]
}

///|
pub fn HttpResponse::new(code : Int) -> HttpResponse {
  { code, headers: {} }
}

///|
pub fn HttpResponse::with_headers(
  code : Int,
  headers : Map[String, String],
) -> HttpResponse {
  { code, headers }
}

///|
/// HTTP client trait for abstracting HTTP operations
/// Implementations:
/// - Native: Uses @http package (real HTTP)
/// - WASM/JS: Uses browser fetch API
/// - Test: Mock implementation for testing
pub(open) trait HttpClient {
  /// Perform HTTP GET request
  /// Returns (response, body) or raises GitError
  get(Self, String, Map[String, String]) -> (HttpResponse, Bytes) raise GitError

  /// Perform HTTP POST request
  /// Returns (response, body) or raises GitError
  post(Self, String, Bytes, Map[String, String]) -> (HttpResponse, Bytes) raise GitError
}

///|
/// Mock HTTP client for testing
pub struct MockHttpClient {
  responses : Map[String, (Int, Bytes)]
}

///|
pub fn MockHttpClient::new() -> MockHttpClient {
  { responses: {} }
}

///|
pub fn MockHttpClient::add_response(
  self : MockHttpClient,
  url : String,
  code : Int,
  body : Bytes,
) -> Unit {
  self.responses[url] = (code, body)
}

///|
pub impl HttpClient for MockHttpClient with get(self, url, _headers) {
  match self.responses.get(url) {
    Some((code, body)) => (HttpResponse::new(code), body)
    None => raise GitError::IoError("Mock: No response for URL: " + url)
  }
}

///|
pub impl HttpClient for MockHttpClient with post(self, url, _body, _headers) {
  match self.responses.get(url) {
    Some((code, body)) => (HttpResponse::new(code), body)
    None => raise GitError::IoError("Mock: No response for URL: " + url)
  }
}
