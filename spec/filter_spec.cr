require "spec"
require "../src/nostr"

EVENT_JSON = %({"id":"#{"a" * 64}","pubkey":"#{"b" * 64}","created_at":100,"kind":1,"tags":[["e","#{"c" * 64}"],["t","nostr"]],"content":"hello","sig":"#{"d" * 128}"})

describe Nostr::Filter do
  event = Nostr::Event.from_json(EVENT_JSON)

  it "matches events without empty lists" do
    Nostr::Filter.from_json(%({"limit":3})).matches?(event).should be_true
    Nostr::Filter.from_json(%({"kinds":[1],"#t":["nostr"]})).matches?(event).should be_true
  end

  it "parses arbitrary tag filters" do
    Nostr::Filter.from_json(%({"#t":["other"]})).matches?(event).should be_false
  end

  it "matches nothing when any list is empty" do
    [%({"ids":[]}), %({"authors":[]}), %({"kinds":[]}), %({"#e":[]}), %({"#p":[]}), %({"#t":[]}), %({"kinds":[1],"#t":[]})].each do |json|
      filter = Nostr::Filter.from_json(json)
      filter.match_nothing?.should be_true
      filter.matches?(event).should be_false
    end
  end
end

describe "DB.count" do
  DB::POOL.exec("INSERT INTO event (id, pubkey, created_at, kind, tags, content, sig) VALUES ($1, $2, 100, 1, $3::jsonb, 'hello', $4) ON CONFLICT DO NOTHING",
    "a" * 64, "b" * 64, %([["e","#{"c" * 64}"],["t","nostr"]]), "d" * 128)

  it "counts nothing for filters with an empty list" do
    filters = [%({"ids":[]}), %({"authors":[]}), %({"kinds":[]}), %({"#e":[]}), %({"#t":[]})].map { |json| Nostr::Filter.from_json(json) }
    DB.count(filters, Set(String).new).should eq(0)
    DB.count([Nostr::Filter.from_json(%({"kinds":[1]}))], Set(String).new).should be > 0
  end

  it "counts an event matching several filters once" do
    filters = [%({"ids":["#{"a" * 64}"]}), %({"authors":["#{"b" * 64}"]}), %({"#t":["nostr"]}), %({"kinds":[]})].map { |json| Nostr::Filter.from_json(json) }
    DB.count(filters, Set(String).new).should eq(1)
  end
end
