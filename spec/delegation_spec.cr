require "spec"
require "../src/delegation"

# x coordinate of the secp256k1 generator point, i.e. the public key for
# secret key 1.
DELEGATOR_PUBKEY = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
DELEGATEE_PUBKEY = "1111111111111111111111111111111111111111111111111111111111111111"
CONDITIONS       = "kind=1&created_at>1&created_at<4102444800"
# BIP-340 signature by secret key 1 over
# sha256("nostr:delegation:#{DELEGATEE_PUBKEY}:#{CONDITIONS}").
SIGNATURE = "7f410523d9c9232a7af8f3cd0c806e84ab1971a5918c990e60338d33b50c1164195bb89e95b4a7494d5ae7e98140c8c85a622f3f5edb7fbdba1be5ab6941a871"
# BIP-340 signature over the same token by secret key 2, i.e. a key other
# than the delegator's.
WRONG_KEY_SIGNATURE = "066be732d2f021522546bf36b4c654c933cd5682b1b4c20d75ab4d32b596b1e194d66033c18dc1a34a15fae671be320628c6549e3c376d4e018b48432b24c0ab"

describe Nostr::Delegation do
  it "accepts events without a delegation tag" do
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, [] of Array(String)).should be_true
  end

  it "accepts a valid delegation" do
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_true
  end

  it "rejects a delegation tag with extra elements" do
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE, "extra"]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end

  it "rejects an empty delegator pubkey" do
    tags = [["delegation", "", CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end

  it "rejects a non-hex delegator pubkey" do
    tags = [["delegation", "zz" * 32, CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end

  it "rejects a kind not allowed by the conditions" do
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 2, 100_i64, tags).should be_false
  end

  it "rejects created_at at or after the upper bound" do
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 4102444800_i64, tags).should be_false
  end

  it "rejects created_at at or before the lower bound" do
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 1_i64, tags).should be_false
  end

  it "rejects an out-of-range signature" do
    # r and s fall outside the field / group order.
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, "ff" * 64]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end

  it "rejects a forged in-range signature" do
    # The valid signature with one byte of s flipped: r and s are still in
    # range, so only the BIP-340 challenge comparison can reject it.
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, SIGNATURE.sub(126, "2")]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end

  it "rejects a signature by a key other than the delegator" do
    # A valid BIP-340 signature over the delegation token, but made with
    # secret key 2 instead of the delegator's key.
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, WRONG_KEY_SIGNATURE]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end
end
