require "pg"

# PG::ResultSet#do_close (crystal-pg 0.29) returns the connection to the pool
# first and only then skips the rows that were not read. Skipping waits on the
# socket, so another fiber can check the connection out in the meantime and
# its query reads our leftover rows. The protocol stream goes out of sync and
# a garbage frame length makes PQ::Connection#read allocate gigabytes. This
# happens whenever a subscription stops reading its history query early.
# Skip the remaining rows first, then release the connection.
class PG::ResultSet
  protected def do_close
    skip_remaining_rows unless @end
  rescue DB::ConnectionLost
    # if the connection is lost there is nothing to be
    # done since the result set is no longer needed
  ensure
    statement.release_from_result_set
  end

  private def skip_remaining_rows
    # Check if we didn't advance to the first row
    if @column_index == -1
      return unless move_next
    end

    fields = @fields

    loop do
      # Skip remaining columns
      while fields && @column_index < fields.size
        skip
      end

      break unless move_next
    end
  end
end
