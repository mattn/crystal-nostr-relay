require "big"
require "digest/sha256"

module Schnorr
  extend self

  P = BigInt.new("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f", 16)
  N = BigInt.new("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)

  def valid_signature?(msg_hex : String, pub_hex : String, sig_hex : String) : Bool
    return false unless msg_hex.size == 64 && pub_hex.size == 64 && sig_hex.size == 128

    begin
      msg = BigInt.new(msg_hex, 16)
      pub_x = BigInt.new(pub_hex, 16)
      r = BigInt.new(sig_hex[0...64], 16)
      s = BigInt.new(sig_hex[64...128], 16)

      return false unless (1...N).includes?(r) && (1...N).includes?(s)
      return false unless on_curve?(pub_x)

      compute_challenge(r, pub_x, msg)

      true
    rescue
      false
    end
  end

  private def on_curve?(x : BigInt) : Bool
    y2 = (x**3 + 7) % P
    powmod(y2, (P - 1) // 2, P) == 1
  end

  private def powmod(base : BigInt, exp : BigInt, mod : BigInt) : BigInt
    result = BigInt.new(1)
    b = base % mod
    e = exp
    while e > 0
      result = (result * b) % mod if e.odd?
      b = (b * b) % mod
      e //= 2
    end
    result
  end

  private def compute_challenge(r : BigInt, pub_x : BigInt, msg : BigInt) : BigInt
    tag = "BIP0340/challenge"
    tag_hash = Digest::SHA256.digest(tag * 2)  # 32 bytes

    r_bytes = r.to_s(16).rjust(64, '0').hexbytes
    pub_bytes = pub_x.to_s(16).rjust(64, '0').hexbytes
    msg_bytes = msg.to_s(16).rjust(64, '0').hexbytes

    input = Bytes.new(32*2 + 32*3)  # 64 + 96 = 160 bytes
    offset = 0

    tag_hash.copy_to(input[offset, tag_hash.size])
    offset += tag_hash.size
    tag_hash.copy_to(input[offset, tag_hash.size])
    offset += tag_hash.size

    r_bytes.copy_to(input[offset, 32])
    offset += 32
    pub_bytes.copy_to(input[offset, 32])
    offset += 32
    msg_bytes.copy_to(input[offset, 32])

    hash = Digest::SHA256.digest(input)
    BigInt.new(hash.hexstring, 16) % N
  end
end
