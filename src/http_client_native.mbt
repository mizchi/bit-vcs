///| Native HTTP client implementation using @http package

///| This file is only compiled for native target

///|
pub struct NativeHttpClient {
  // No state needed, uses @http directly
  dummy : Int
}

///|
pub fn NativeHttpClient::new() -> NativeHttpClient {
  { dummy: 0 }
}

///|
pub async fn native_http_get(
  url : String,
  headers : Map[String, String],
) -> (HttpResponse, Bytes) raise GitError {
  let (response, client) = @http.get_stream(url, headers~) catch {
    e => raise GitError::IoError("HTTP GET failed: \{e}")
  }
  let chunks : Array[Byte] = []
  while true {
    let chunk = client.read_some() catch { _ => break }
    match chunk {
      Some(b) =>
        for byte in b {
          chunks.push(byte)
        }
      None => break
    }
  }
  client.close()
  let data = Bytes::from_array(
    FixedArray::makei(chunks.length(), fn(i) { chunks[i] }),
  )
  (HttpResponse::new(response.code), data)
}

///|
pub async fn native_http_post(
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> (HttpResponse, Bytes) raise GitError {
  let client = @http.post_stream(url, headers~) catch {
    e => raise GitError::IoError("HTTP POST failed: \{e}")
  }
  client.write(body) catch {
    e => raise GitError::IoError("HTTP POST write failed: \{e}")
  }
  let response = client.end_request() catch {
    e => raise GitError::IoError("HTTP POST end_request failed: \{e}")
  }
  let chunks : Array[Byte] = []
  while true {
    let chunk = client.read_some() catch { _ => break }
    match chunk {
      Some(b) =>
        for byte in b {
          chunks.push(byte)
        }
      None => break
    }
  }
  client.close()
  let data = Bytes::from_array(
    FixedArray::makei(chunks.length(), fn(i) { chunks[i] }),
  )
  (HttpResponse::new(response.code), data)
}
