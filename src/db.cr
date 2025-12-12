# src/db.cr
require "pg"
require "db"
require "json"

module DB
  DB_URL = ENV["DATABASE_URL"]? || "postgres://localhost/nostr"

  # Database connection pool
  POOL = ::DB.open(DB_URL)

  # Close connection on exit
  at_exit { POOL.close }

  # Create tags_to_tagvalues function if not exists
  POOL.exec <<-SQL
    CREATE OR REPLACE FUNCTION tags_to_tagvalues(jsonb) RETURNS text[]
    AS 'SELECT array_agg(t->>1) FROM (SELECT jsonb_array_elements($1) AS t)s WHERE length(t->>0) = 1;'
    LANGUAGE SQL
    IMMUTABLE
    RETURNS NULL ON NULL INPUT;
  SQL

  puts "Database function tags_to_tagvalues created/verified"

  # Create event table if not exists
  puts "Creating event table..."
  POOL.exec <<-SQL
    CREATE TABLE IF NOT EXISTS event (
      id text NOT NULL,
      pubkey text NOT NULL,
      created_at integer NOT NULL,
      kind integer NOT NULL,
      tags jsonb NOT NULL,
      content text NOT NULL,
      sig text NOT NULL,
      tagvalues text[] GENERATED ALWAYS AS (tags_to_tagvalues(tags)) STORED
    );
  SQL

  puts "Creating indexes..."
  # Create indexes
  POOL.exec "CREATE UNIQUE INDEX IF NOT EXISTS ididx ON event USING btree (id text_pattern_ops);"
  POOL.exec "CREATE INDEX IF NOT EXISTS pubkeyprefix ON event USING btree (pubkey text_pattern_ops);"
  POOL.exec "CREATE INDEX IF NOT EXISTS timeidx ON event (created_at DESC);"
  POOL.exec "CREATE INDEX IF NOT EXISTS kindidx ON event (kind);"
  POOL.exec "CREATE INDEX IF NOT EXISTS kindtimeidx ON event(kind, created_at DESC);"
  POOL.exec "CREATE INDEX IF NOT EXISTS arbitrarytagvalues ON event USING gin (tagvalues);"

  puts "Database setup completed successfully"

  # Save event
  def self.save(event : Nostr::Event) : Bool
    POOL.transaction do |tx|
      conn = tx.connection
      
      # Don't save ephemeral events
      return true if event.ephemeral?

      # For replaceable events, delete old events
      if event.replaceable?
        conn.exec(
          "DELETE FROM event WHERE pubkey = $1 AND kind = $2",
          event.pubkey,
          event.kind
        )
      end

      # For parameterized replaceable events, delete old events with same d tag
      if event.parameterized_replaceable?
        d_tag = event.d_tag || ""
        conn.exec(
          "DELETE FROM event WHERE pubkey = $1 AND kind = $2 AND tags @> $3::jsonb",
          event.pubkey,
          event.kind,
          %([["d","#{d_tag}"]])
        )
      end

      # Insert event
      conn.exec(
        "INSERT INTO event (id, pubkey, created_at, kind, tags, content, sig)
         VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
         ON CONFLICT (id) DO NOTHING",
        event.id,
        event.pubkey,
        event.created_at.to_i32,
        event.kind,
        event.tags.to_json,
        event.content,
        event.sig
      )
    end

    true
  rescue ex
    Log.error { "DB save error: #{ex.message}" }
    false
  end

  # NIP-09: Event deletion via kind 5
  def self.delete_events(deletion_event : Nostr::Event) : Bool
    return false unless deletion_event.kind == 5

    e_tags = deletion_event.e_tags
    return false if e_tags.empty?

    POOL.transaction do |tx|
      conn = tx.connection

      e_tags.each do |event_id|
        # Fetch target event to delete
        result = conn.query_one?(
          "SELECT pubkey, kind, tags::text FROM event WHERE id = $1",
          event_id,
          as: {String, Int32, String}
        )
        
        next unless result
        target_pubkey, target_kind, target_tags_json = result

        # Special handling for kind 1059 (Sealed/Gift Wrap)
        if target_kind == 1059
          # Extract p tags from kind 1059 event
          target_tags = Array(Array(String)).from_json(target_tags_json)
          p_tags = target_tags.select { |t| t.size >= 2 && t[0] == "p" }.map(&.[1])
          
          # Delete only if deletion_event pubkey is in kind 1059's p-tags
          if p_tags.includes?(deletion_event.pubkey)
            conn.exec("DELETE FROM event WHERE id = $1", event_id)
            Log.info { "Deleted kind 1059 event #{event_id} by p-tag owner #{deletion_event.pubkey}" }
          else
            Log.warn { "Deletion denied: kind 5 pubkey #{deletion_event.pubkey} not in kind 1059 p-tags" }
          end
        else
          # Regular events: delete only if pubkey matches
          if target_pubkey == deletion_event.pubkey
            conn.exec("DELETE FROM event WHERE id = $1", event_id)
            Log.info { "Deleted event #{event_id} by owner #{deletion_event.pubkey}" }
          else
            Log.warn { "Deletion denied: pubkey mismatch for event #{event_id}" }
          end
        end
      end
    end

    true
  rescue ex
    Log.error { "DB delete error: #{ex.message}" }
    false
  end

  # Return matched events (limit)
  def self.query(filters : Array(Nostr::Filter), &block : Nostr::Event ->)
    # Match any filter (OR condition)
    filters.each do |filter|
      sql, args = build_query(filter)
      POOL.query(sql, args: args) do |rs|
        rs.each do
          event = Nostr::Event.from_json(rs.read(String))
          yield event
        end
      end
    end
  end

  # Build SQL query for a single filter
  private def self.build_query(filter : Nostr::Filter) : {String, Array(::DB::Any)}
    conditions = [] of String
    args = [] of ::DB::Any
    arg_counter = 0

    # ids => id LIKE 'prefix%'
    if ids = filter.ids
      unless ids.empty?
        placeholders = ids.map do |id|
          args << "#{id}%"
          "$#{arg_counter += 1}"
        end.join(", ")
        conditions << "id LIKE ANY (ARRAY[#{placeholders}])"
      end
    end

    # authors => pubkey LIKE 'prefix%'
    if authors = filter.authors
      unless authors.empty?
        placeholders = authors.map do |author|
          args << "#{author}%"
          "$#{arg_counter += 1}"
        end.join(", ")
        conditions << "pubkey LIKE ANY (ARRAY[#{placeholders}])"
      end
    end

    # kinds => kind IN (...)
    if kinds = filter.kinds
      unless kinds.empty?
        placeholders = kinds.map do |kind|
          args << kind
          "$#{arg_counter += 1}"
        end.join(", ")
        conditions << "kind IN (#{placeholders})"
      end
    end

    # since / until
    if since = filter.since
      args << since
      conditions << "created_at >= $#{arg_counter += 1}"
    end

    if until_ = filter.until_
      args << until_
      conditions << "created_at <= $#{arg_counter += 1}"
    end

    # #e and #p => tagvalues @> ARRAY[...]
    {% for tag in ["e", "p"] %}
      if values = filter.{{tag.id}}
        unless values.empty?
          placeholders = values.map do |v|
            args << v
            "$#{arg_counter += 1}"
          end.join(", ")
          conditions << "tagvalues @> ARRAY[#{placeholders}]::text[]"
        end
      end
    {% end %}

    # Arbitrary tags (#t, #r, #challenge, etc.)
    filter.generic.each do |key, values|
      next if values.empty?
      placeholders = values.map do |v|
        args << v
        "$#{arg_counter += 1}"
      end.join(", ")
      conditions << "tagvalues @> ARRAY[#{placeholders}]::text[]"
    end

    # WHERE clause (default to true if empty)
    where_clause = conditions.empty? ? "true" : conditions.join(" AND ")

    # LIMIT (default 500)
    limit = filter.limit || 500
    args << limit

    sql = <<-SQL
      SELECT row_to_json(e)::text
      FROM event e
      WHERE #{where_clause}
      ORDER BY created_at DESC
      LIMIT $#{arg_counter + 1}
    SQL

    {sql, args}
  end
end
