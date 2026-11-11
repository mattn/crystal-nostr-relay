require "spec"
require "../src/pow"

describe Nostr::Pow do
  it "counts leading zero bits of a hex id" do
    Nostr::Pow.difficulty("ffff").should eq 0
    Nostr::Pow.difficulty("7fff").should eq 1
    Nostr::Pow.difficulty("3fff").should eq 2
    Nostr::Pow.difficulty("1fff").should eq 3
    Nostr::Pow.difficulty("0fff").should eq 4
    Nostr::Pow.difficulty("00ff").should eq 8
    Nostr::Pow.difficulty("002f").should eq 10
    Nostr::Pow.difficulty("0001").should eq 15
    Nostr::Pow.difficulty("000000000e9d897a3aa5f").should eq 36
    Nostr::Pow.difficulty("0" * 64).should eq 256
    Nostr::Pow.difficulty("").should eq 0
  end

  it "stops at a non-hex character" do
    Nostr::Pow.difficulty("00zz").should eq 8
  end
end
