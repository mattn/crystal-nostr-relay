require "big"
require "digest/sha256"

module Schnorr
  extend self

  P  = BigInt.new("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f", 16)
  N  = BigInt.new("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)
  GX = BigInt.new("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", 16)
  GY = BigInt.new("483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8", 16)

  # An affine point on secp256k1; nil is the point at infinity.
  alias Point = Tuple(BigInt, BigInt)?

  # Full BIP-340 Schnorr verification: lift the x-only public key to a
  # point P with even y, compute the tagged challenge
  # e = int(sha256(sha256(tag) || sha256(tag) || r || pubkey || msg)) mod n
  # and accept iff R = s*G - e*P is not infinity, has even y and x(R) == r.
  def valid_signature?(msg_hex : String, pub_hex : String, sig_hex : String) : Bool
    return false unless msg_hex.size == 64 && pub_hex.size == 64 && sig_hex.size == 128

    begin
      msg_bytes = msg_hex.hexbytes
      pub_bytes = pub_hex.hexbytes
      r_bytes = sig_hex[0...64].hexbytes
      pub_x = BigInt.new(pub_hex, 16)
      r = BigInt.new(sig_hex[0...64], 16)
      s = BigInt.new(sig_hex[64...128], 16)

      return false unless r < P && s < N

      pub = lift_x(pub_x)
      return false unless pub

      e = challenge(r_bytes, pub_bytes, msg_bytes)
      point = point_add(point_mul({GX, GY}, s), point_mul(pub, N - e))
      return false unless point

      x, y = point
      y.even? && x == r
    rescue
      false
    end
  end

  # Returns the curve point with the given x coordinate and even y,
  # or nil when x is out of range or not on the curve.
  private def lift_x(x : BigInt) : Point
    return nil if x < 0 || x >= P
    y2 = (x * x % P * x + 7) % P
    y = powmod(y2, (P + 1) // 4, P)
    return nil unless (y * y) % P == y2
    y = P - y if y.odd?
    {x, y}
  end

  private def point_add(p1 : Point, p2 : Point) : Point
    return p2 unless p1
    return p1 unless p2

    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2
      return nil if (y1 + y2) % P == 0
      lam = 3 * x1 * x1 % P * modinv(2 * y1) % P
    else
      lam = (y2 - y1) * modinv(x2 - x1) % P
    end
    x3 = (lam * lam - x1 - x2) % P
    {x3, (lam * (x1 - x3) - y1) % P}
  end

  private def point_mul(point : Point, k : BigInt) : Point
    result : Point = nil
    addend = point
    while k > 0
      result = point_add(result, addend) if k.odd?
      addend = point_add(addend, addend)
      k //= 2
    end
    result
  end

  private def modinv(a : BigInt) : BigInt
    powmod(a % P, P - 2, P)
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

  private def challenge(r_bytes : Bytes, pub_bytes : Bytes, msg_bytes : Bytes) : BigInt
    tag_hash = Digest::SHA256.digest("BIP0340/challenge")

    input = Bytes.new(tag_hash.size * 2 + 32 * 3)
    offset = 0
    {tag_hash, tag_hash, r_bytes, pub_bytes, msg_bytes}.each do |part|
      part.copy_to(input[offset, part.size])
      offset += part.size
    end

    hash = Digest::SHA256.digest(input)
    BigInt.new(hash.hexstring, 16) % N
  end
end
