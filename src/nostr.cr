require "http/server"
require "http/web_socket"
require "json"
require "digest/sha256"

require "./db"
require "./schnorr"

module Nostr
  struct Event
    include JSON::Serializable

    getter id : String
    getter pubkey : String
    getter created_at : Int64
    getter kind : Int32
    getter tags : Array(Array(String))
    getter content : String
    getter sig : String

    def valid_signature? : Bool
      Schnorr.valid_signature?(id, pubkey, sig)
    end

    def valid? : Bool
      id == compute_id && valid_signature?
    end

    # NIP-01: Regular events: 1000 <= kind < 10000
    # NIP-16: Ephemeral events: 20000 <= kind < 30000
    # NIP-01: Replaceable events: 0, 3, 10000 <= kind < 20000
    # NIP-01: Parameterized replaceable events: 30000 <= kind < 40000
    def ephemeral? : Bool
      kind >= 20000 && kind < 30000
    end

    def replaceable? : Bool
      kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000)
    end

    def parameterized_replaceable? : Bool
      kind >= 30000 && kind < 40000
    end

    def d_tag : String?
      tags.find { |t| t.size >= 2 && t[0] == "d" }.try(&.[1])
    end

    def e_tags : Array(String)
      tags.select { |t| t.size >= 2 && t[0] == "e" }.map(&.[1])
    end

    def p_tags : Array(String)
      tags.select { |t| t.size >= 2 && t[0] == "p" }.map(&.[1])
    end

    def expiration_timestamp : Int64?
      expiration_tag = tags.find { |t| t.size >= 2 && t[0] == "expiration" }
      return nil unless expiration_tag
      begin
        expiration_tag[1].to_i64
      rescue ArgumentError
        nil
      end
    end

    def expired? : Bool
      exp_ts = expiration_timestamp
      return false unless exp_ts
      Time.utc.to_unix >= exp_ts
    end

    private def compute_id : String
      data = [0i64, pubkey, created_at, kind, tags, content]
      Digest::SHA256.hexdigest(data.to_json)
    end
  end

  struct Filter
    include JSON::Serializable

    getter ids : Array(String)?
    getter kinds : Array(Int32)?
    getter authors : Array(String)?
    getter since : Int64?
    @[JSON::Field(key: "until")]
    getter until_ : Int64?
    getter limit : Int32?

    @[JSON::Field(key: "#e")]
    getter e : Array(String)?
    @[JSON::Field(key: "#p")]
    getter p : Array(String)?

    property generic : Hash(String, Array(String)) = Hash(String, Array(String)).new

    def initialize(**args)
      super
      args.each do |k, v|
        if k.to_s.starts_with?("#") && v.is_a?(Array(String))
          generic[k.to_s] = v
        end
      end
    end

    def matches?(event : Event) : Bool
      if ids = self.ids
        return false unless ids.any? { |i| event.id.starts_with?(i) }
      end
      if kinds = self.kinds
        return false unless kinds.includes?(event.kind)
      end
      if authors = self.authors
        return false unless authors.any? { |a| event.pubkey.starts_with?(a) }
      end
      if since = self.since
        return false if event.created_at < since
      end
      if until_ = self.until_
        return false if event.created_at > until_
      end
      if e = self.e
        return false unless event.tags.any? { |t| t[0]? == "e" && e.includes?(t[1]?) }
      end
      if p = self.p
        return false unless event.tags.any? { |t| t[0]? == "p" && p.includes?(t[1]?) }
      end
      generic.each do |key, values|
        tag_name = key[1..]
        return false unless event.tags.any? { |t| t[0]? == tag_name && values.includes?(t[1]?) }
      end
      true
    end
  end

  record EventMessage, event : Event
  record RequestMessage, sub_id : String, filters : Array(Filter)
  record CountMessage, sub_id : String, filters : Array(Filter)
  record CloseMessage, sub_id : String
  record Subscription, sub_id : String, filters : Array(Filter), channel : Channel(Event), eose_channel : Channel(Nil)

  alias RelayMessage = EventMessage | RequestMessage | CountMessage | CloseMessage | JSON::PullParser::Kind

  def self.parse(json : String) : RelayMessage
    pull = JSON::PullParser.new(json)
    pull.read_begin_array
    tag = pull.read_string
    case tag
    when "EVENT"
      event = Event.from_json(pull.read_raw)
      pull.read_end_array
      return EventMessage.new(event)
    when "REQ"
      sub_id = pull.read_string
      filters = [] of Filter
      while pull.kind != JSON::PullParser::Kind::EndArray
        filters << Filter.from_json(pull.read_raw)
      end
      pull.read_end_array
      return RequestMessage.new(sub_id, filters)
    when "COUNT"
      sub_id = pull.read_string
      filters = [] of Filter
      while pull.kind != JSON::PullParser::Kind::EndArray
        filters << Filter.from_json(pull.read_raw)
      end
      pull.read_end_array
      return CountMessage.new(sub_id, filters)
    when "CLOSE"
      reason = pull.read_string
      pull.read_end_array
      return CloseMessage.new(reason)
    else
      raise "unknown message: #{tag}"
    end
  end
end

# ------------------------------
# Client Class (registered to ClientManager automatically)
# ------------------------------
class Client
  getter ws : HTTP::WebSocket
  getter subscriptions = Hash(String, Nostr::Subscription).new
  @closed = Atomic(Int32).new(0)

  def initialize(@ws)
    ClientManager.add(self)
  end

  def close
    return unless @closed.swap(1) == 0
    subscriptions.each_value do |sub|
      sub.channel.close
      sub.eose_channel.close
    end
    ClientManager.remove(self)
  end

  def subscribe(id : String, filters : Array(Nostr::Filter))
    subscriptions[id]?.try do |old_sub|
      old_sub.channel.close
      old_sub.eose_channel.close
    end
    channel = Channel(Nostr::Event).new(100)
    eose_channel = Channel(Nil).new(1)
    sub = Nostr::Subscription.new(id, filters, channel, eose_channel)
    subscriptions[id] = sub

    # Dedicated sender fiber for this subscription
    spawn send_events(sub)

    # Query execution fiber
    spawn do
      begin
        DB.query(filters) do |event|
          begin
            channel.send(event)
          rescue Channel::ClosedError
            break
          end
        end
        # All events sent to channel, signal EOSE
        eose_channel.send(nil)
      rescue ex
        Log.error { "Subscribe query error: #{ex.message}" }
        Log.error { ex.backtrace.join("\n") }
      end
    end
  end

  private def send_events(sub : Nostr::Subscription)
    loop do
      break if @closed.get != 0
      select
      when event = sub.channel.receive
        ws.send %(["EVENT","#{sub.sub_id}",#{event.to_json}])
      when sub.eose_channel.receive
        ws.send %(["EOSE","#{sub.sub_id}"])
        break
      end
    end
  rescue Channel::ClosedError
    # Normal termination
  rescue ex
    Log.error { "Send event error: #{ex.message}" }
  end

  def unsubscribe(id : String)
    subscriptions.delete(id).try do |sub|
      sub.channel.close
      sub.eose_channel.close
    end
  end

  def broadcast_event(event : Nostr::Event)
    subscriptions.each_value do |sub|
      if sub.filters.any?(&.matches?(event))
        sub.channel.send(event)
      end
    end
  end
end

# ------------------------------
# ClientManager
# ------------------------------
module ClientManager
  @@clients = [] of Client

  def self.add(client : Client)
    @@clients << client
  end

  def self.remove(client : Client)
    @@clients.delete(client)
  end

  def self.broadcast(event : Nostr::Event)
    @@clients.each { |c| spawn c.broadcast_event(event) }
  end
end
