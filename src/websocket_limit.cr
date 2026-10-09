require "http/web_socket"

# Largest client message accepted, whether it arrives as one frame or
# reassembled from fragments.
MAX_MESSAGE_SIZE = 512 * 1024

# HTTP::WebSocket#run buffers a message without any size limit, so one huge
# frame grows the heap by several times its size, and Boehm GC rarely hands
# that memory back to the OS. This is the stdlib loop (Crystal 1.18) with a
# size check in front of every buffered write: a message that would exceed
# MAX_MESSAGE_SIZE closes the connection with 1009 (message too big).
class HTTP::WebSocket
  def run : Nil
    loop do
      begin
        info = @ws.receive(@buffer)
      rescue
        @on_close.try &.call(CloseCode::AbnormalClosure, "")
        @closed = true
        break
      end

      if @current_message.size + info.size > MAX_MESSAGE_SIZE
        @current_message = IO::Memory.new
        @on_close.try &.call(CloseCode::MessageTooBig, "message too large")
        close(CloseCode::MessageTooBig, "message too large") rescue nil
        break
      end

      case info.opcode
      in .ping?
        @current_message.write @buffer[0, info.size]
        if info.final
          message = @current_message.to_s
          do_ping(message)
          @current_message.clear
        end
      in .pong?
        @current_message.write @buffer[0, info.size]
        if info.final
          @on_pong.try &.call(@current_message.to_s)
          @current_message.clear
        end
      in .text?
        @current_message.write @buffer[0, info.size]
        if info.final
          @on_message.try &.call(@current_message.to_s)
          @current_message.clear
        end
      in .binary?
        @current_message.write @buffer[0, info.size]
        if info.final
          @on_binary.try &.call(@current_message.to_slice)
          @current_message.clear
        end
      in .close?
        @current_message.write @buffer[0, info.size]
        if info.final
          @current_message.rewind

          if @current_message.size >= 2
            code = @current_message.read_bytes(UInt16, IO::ByteFormat::NetworkEndian).to_i
            code = CloseCode.new(code)
          else
            code = CloseCode::NoStatusReceived
          end
          message = @current_message.gets_to_end

          do_close(code, message)

          @current_message.clear
          break
        end
      in .continuation?
      end
    end
  end
end
