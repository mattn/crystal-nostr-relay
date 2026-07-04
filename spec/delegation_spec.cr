require "spec"
require "../src/delegation"

# x coordinate of the secp256k1 generator point; a valid x-only pubkey.
DELEGATOR_PUBKEY = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
DELEGATEE_PUBKEY = "1111111111111111111111111111111111111111111111111111111111111111"
CONDITIONS       = "kind=1&created_at>1&created_at<4102444800"
SIGNATURE        = "22" * 64

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

  it "rejects a forged signature" do
    # r and s fall outside [1, N), so the signature cannot be valid.
    tags = [["delegation", DELEGATOR_PUBKEY, CONDITIONS, "ff" * 64]]
    Nostr::Delegation.valid?(DELEGATEE_PUBKEY, 1, 100_i64, tags).should be_false
  end
end
