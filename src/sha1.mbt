///| SHA-1 implementation for Git object hashing

///|
/// SHA-1 initial hash values
let sha1_h0 : Int = 0x67452301

///|
let sha1_h1 : Int = 0xefcdab89

///|
let sha1_h2 : Int = 0x98badcfe

///|
let sha1_h3 : Int = 0x10325476

///|
let sha1_h4 : Int = 0xc3d2e1f0

///|
/// SHA-1 round constants
let sha1_k0 : Int = 0x5a827999

///|
let sha1_k1 : Int = 0x6ed9eba1

///|
let sha1_k2 : Int = 0x8f1bbcdc

///|
let sha1_k3 : Int = 0xca62c1d6

///|
/// Left rotate 32-bit integer
fn rotl32(x : Int, n : Int) -> Int {
  ((x << n) | (x.reinterpret_as_uint() >> (32 - n)).reinterpret_as_int()) &
  0xffffffff
}

///|
/// Incremental SHA-1 state
pub struct Sha1State {
  h : FixedArray[Int]
  block : FixedArray[Byte]
  w : FixedArray[Int]
  mut block_len : Int
  mut total_len : Int64
}

///|
pub fn Sha1State::new() -> Sha1State {
  {
    h: [sha1_h0, sha1_h1, sha1_h2, sha1_h3, sha1_h4],
    block: FixedArray::make(64, b'\x00'),
    w: FixedArray::make(80, 0),
    block_len: 0,
    total_len: 0L,
  }
}

///|
pub fn Sha1State::reset(self : Sha1State) -> Unit {
  self.h[0] = sha1_h0
  self.h[1] = sha1_h1
  self.h[2] = sha1_h2
  self.h[3] = sha1_h3
  self.h[4] = sha1_h4
  self.block_len = 0
  self.total_len = 0L
}

///|
fn Sha1State::process_block(self : Sha1State) -> Unit {
  let h = self.h
  let w = self.w
  let block = self.block
  for i = 0; i < 16; i = i + 1 {
    w[i] = (block[i * 4].to_int() << 24) |
      (block[i * 4 + 1].to_int() << 16) |
      (block[i * 4 + 2].to_int() << 8) |
      block[i * 4 + 3].to_int()
  }
  for i = 16; i < 80; i = i + 1 {
    w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
  }
  let mut a = h[0]
  let mut b = h[1]
  let mut c = h[2]
  let mut d = h[3]
  let mut e = h[4]
  for i = 0; i < 20; i = i + 1 {
    let f = (b & c) | (b.lnot() & d)
    let temp = (rotl32(a, 5) + f + e + sha1_k0 + w[i]) & 0xffffffff
    e = d
    d = c
    c = rotl32(b, 30)
    b = a
    a = temp
  }
  for i = 20; i < 40; i = i + 1 {
    let f = b ^ c ^ d
    let temp = (rotl32(a, 5) + f + e + sha1_k1 + w[i]) & 0xffffffff
    e = d
    d = c
    c = rotl32(b, 30)
    b = a
    a = temp
  }
  for i = 40; i < 60; i = i + 1 {
    let f = (b & c) | (b & d) | (c & d)
    let temp = (rotl32(a, 5) + f + e + sha1_k2 + w[i]) & 0xffffffff
    e = d
    d = c
    c = rotl32(b, 30)
    b = a
    a = temp
  }
  for i = 60; i < 80; i = i + 1 {
    let f = b ^ c ^ d
    let temp = (rotl32(a, 5) + f + e + sha1_k3 + w[i]) & 0xffffffff
    e = d
    d = c
    c = rotl32(b, 30)
    b = a
    a = temp
  }
  h[0] = (h[0] + a) & 0xffffffff
  h[1] = (h[1] + b) & 0xffffffff
  h[2] = (h[2] + c) & 0xffffffff
  h[3] = (h[3] + d) & 0xffffffff
  h[4] = (h[4] + e) & 0xffffffff
}

///|
pub fn Sha1State::update(self : Sha1State, data : Bytes) -> Unit {
  self.update_slice(data, 0, data.length())
}

///|
pub fn Sha1State::update_slice(
  self : Sha1State,
  data : Bytes,
  offset : Int,
  len : Int,
) -> Unit {
  let mut pos = offset
  let end = offset + len
  self.total_len += len.to_int64()
  while pos < end {
    let space = 64 - self.block_len
    let to_copy = if end - pos < space { end - pos } else { space }
    for i = 0; i < to_copy; i = i + 1 {
      self.block[self.block_len + i] = data[pos + i]
    }
    self.block_len += to_copy
    pos += to_copy
    if self.block_len == 64 {
      self.process_block()
      self.block_len = 0
    }
  }
}

///|
pub fn Sha1State::update_byte(self : Sha1State, b : Byte) -> Unit {
  self.block[self.block_len] = b
  self.block_len += 1
  self.total_len += 1L
  if self.block_len == 64 {
    self.process_block()
    self.block_len = 0
  }
}

///|
pub fn Sha1State::update_string(self : Sha1State, s : String) -> Unit {
  for c in s {
    self.update_byte(c.to_int().to_byte())
  }
}

///|
pub fn Sha1State::finish(self : Sha1State) -> ObjectId {
  let bit_len = self.total_len * 8L
  self.block[self.block_len] = b'\x80'
  self.block_len += 1
  if self.block_len > 56 {
    while self.block_len < 64 {
      self.block[self.block_len] = b'\x00'
      self.block_len += 1
    }
    self.process_block()
    self.block_len = 0
  }
  while self.block_len < 56 {
    self.block[self.block_len] = b'\x00'
    self.block_len += 1
  }
  self.block[56] = ((bit_len >> 56) & 0xffL).to_byte()
  self.block[57] = ((bit_len >> 48) & 0xffL).to_byte()
  self.block[58] = ((bit_len >> 40) & 0xffL).to_byte()
  self.block[59] = ((bit_len >> 32) & 0xffL).to_byte()
  self.block[60] = ((bit_len >> 24) & 0xffL).to_byte()
  self.block[61] = ((bit_len >> 16) & 0xffL).to_byte()
  self.block[62] = ((bit_len >> 8) & 0xffL).to_byte()
  self.block[63] = (bit_len & 0xffL).to_byte()
  self.process_block()
  let result : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 5; i = i + 1 {
    result[i * 4] = ((self.h[i] >> 24) & 0xff).to_byte()
    result[i * 4 + 1] = ((self.h[i] >> 16) & 0xff).to_byte()
    result[i * 4 + 2] = ((self.h[i] >> 8) & 0xff).to_byte()
    result[i * 4 + 3] = (self.h[i] & 0xff).to_byte()
  }
  ObjectId::new(result)
}

///|
/// Compute SHA-1 hash of data prefix (first `len` bytes).
pub fn sha1_prefix(data : Bytes, len : Int) -> ObjectId {
  let msg_len = if len < 0 {
    0
  } else if len > data.length() {
    data.length()
  } else {
    len
  }
  let state = Sha1State::new()
  state.update_slice(data, 0, msg_len)
  state.finish()
}

///|
/// Compute SHA-1 hash of data
pub fn sha1(data : Bytes) -> ObjectId {
  sha1_prefix(data, data.length())
}

///|
/// Compute SHA-1 hash of Array prefix (first `len` bytes).
pub fn sha1_array_prefix(data : Array[Byte], len : Int) -> ObjectId {
  let msg_len = if len < 0 {
    0
  } else if len > data.length() {
    data.length()
  } else {
    len
  }
  let state = Sha1State::new()
  for i = 0; i < msg_len; i = i + 1 {
    state.update_byte(data[i])
  }
  state.finish()
}

///|
/// Compute SHA-1 hash of data from Array
pub fn sha1_array(data : Array[Byte]) -> ObjectId {
  sha1_array_prefix(data, data.length())
}
