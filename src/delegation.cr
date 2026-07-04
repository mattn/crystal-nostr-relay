require "digest/sha256"

require "./schnorr"

module Nostr
  # NIP-26: Delegated Event Signing
  #
  # An event may carry a tag ["delegation", <delegator pubkey>, <conditions>,
  # <signature>] where <signature> is a Schnorr signature by the delegator
  # over sha256("nostr:delegation:<delegatee pubkey>:<conditions>").
  module Delegation
    extend self

    # Returns true when the event carries no delegation tag, or when the
    # delegation tag is well formed, its conditions are satisfied and its
    # signature is valid.
    def valid?(pubkey : String, kind : Int32, created_at : Int64, tags : Array(Array(String))) : Bool
      delegation_tag = tags.find { |t| t.size >= 4 && t[0] == "delegation" }
      return true unless delegation_tag
      return false unless delegation_tag.size == 4

      delegator_pubkey = delegation_tag[1]
      conditions = delegation_tag[2]
      signature = delegation_tag[3]

      return false if delegator_pubkey.empty? || conditions.empty? || signature.empty?
      return false unless delegator_pubkey.size == 64 && delegator_pubkey.hexbytes?

      return false unless conditions_met?(kind, created_at, conditions)

      valid_signature?(pubkey, delegator_pubkey, conditions, signature)
    end

    # <conditions> is an &-separated query string. The event kind must match
    # one of the kind=<int> fields, and created_at must satisfy every
    # created_at<<int> and created_at><int> field.
    private def conditions_met?(kind : Int32, created_at : Int64, conditions : String) : Bool
      kind_allowed = false
      created_at_valid = true

      conditions.split('&').each do |condition|
        if kind_str = condition.lchop?("kind=")
          if allowed_kind = kind_str.to_i32?
            kind_allowed = true if kind == allowed_kind
          end
        elsif timestamp_str = condition.lchop?("created_at<")
          if max_time = timestamp_str.to_i64?
            created_at_valid = false if created_at >= max_time
          end
        elsif timestamp_str = condition.lchop?("created_at>")
          if min_time = timestamp_str.to_i64?
            created_at_valid = false if created_at <= min_time
          end
        end
      end

      kind_allowed && created_at_valid
    end

    private def valid_signature?(delegatee_pubkey : String, delegator_pubkey : String, conditions : String, signature : String) : Bool
      token = "nostr:delegation:#{delegatee_pubkey}:#{conditions}"
      hash = Digest::SHA256.hexdigest(token)
      Schnorr.valid_signature?(hash, delegator_pubkey, signature)
    end
  end
end
