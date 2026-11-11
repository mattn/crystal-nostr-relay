module Nostr
  # NIP-13: Proof of Work
  module Pow
    # Minimum difficulty required for incoming events (0 disables the check).
    MIN_DIFFICULTY = (ENV["MIN_POW_DIFFICULTY"]? || "0").to_i? || 0

    # Count the number of leading zero bits in a hex-encoded event id.
    def self.difficulty(hex : String) : Int32
      count = 0
      hex.each_char do |c|
        nibble = c.to_i?(16)
        break if nibble.nil?
        if nibble == 0
          count += 4
          next
        end
        if nibble <= 1
          count += 3
        elsif nibble <= 3
          count += 2
        elsif nibble <= 7
          count += 1
        end
        break
      end
      count
    end
  end
end
