require "http/server"
require "http/web_socket"
require "json"
require "log"
require "./nostr"

# NIP-11 Relay Information
RELAY_INFO = {
  name: ENV["RELAY_NAME"]? || "Crystal Nostr Relay",
  description: ENV["RELAY_DESCRIPTION"]? || "A Nostr relay written in Crystal",
  pubkey: ENV["RELAY_PUBKEY"]? || "",
  contact: ENV["RELAY_CONTACT"]? || "",
  icon: ENV["RELAY_ICON"]? || "",
  supported_nips: [1, 2, 4, 9, 11, 12, 15, 16, 20, 28, 33, 40, 45, 65, 70],
  software: "https://github.com/mattn/crystal-nostr-relay",
  version: "0.1.0",
}

# HTTP Handler for NIP-11 and static files
class RelayHandler
  include HTTP::Handler

  def call(context)
    # Check if WebSocket upgrade request
    if context.request.headers["Upgrade"]?.try(&.downcase) == "websocket"
      call_next(context)
      return
    end

    # NIP-11: Return relay information if Accept header includes application/nostr+json
    accept = context.request.headers["Accept"]?
    if accept && accept.includes?("application/nostr+json")
      context.response.headers["Access-Control-Allow-Origin"] = "*"
      context.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Accept"
      context.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
      context.response.content_type = "application/nostr+json"
      context.response.print RELAY_INFO.to_json
      return
    end

    # Serve static files
    path = context.request.path
    path = "/index.html" if path == "/"
    
    file_path = File.join("public", path)
    
    if File.file?(file_path)
      context.response.content_type = mime_type(file_path)
      context.response.print File.read(file_path)
    else
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.content_type = "text/html"
      context.response.print "<h1>404 Not Found</h1>"
    end
  end

  private def mime_type(path : String) : String
    case File.extname(path)
    when ".html", ".htm"
      "text/html"
    when ".css"
      "text/css"
    when ".js"
      "application/javascript"
    when ".json"
      "application/json"
    when ".png"
      "image/png"
    when ".jpg", ".jpeg"
      "image/jpeg"
    when ".gif"
      "image/gif"
    when ".svg"
      "image/svg+xml"
    when ".ico"
      "image/x-icon"
    else
      "application/octet-stream"
    end
  end
end

websocket_handler = HTTP::WebSocketHandler.new() do |ws, ctx|
  client = Client.new(ws)

  ws.on_message do |message|
    begin
      Log.info { "Received message: #{message}" }

      data = Nostr.parse(message)
      case data
      when Nostr::EventMessage
        if data.event.valid?
          # Handle kind 5 (deletion) separately
          if data.event.kind == 5
            DB.delete_events(data.event)
            ws.send %(["OK","#{data.event.id}",true,""])
          else
            saved, message = DB.save(data.event)
            if saved
              ClientManager.broadcast(data.event)
              ws.send %(["OK","#{data.event.id}",true,""])
            else
              ws.send %(["OK","#{data.event.id}",false,"#{message}"])
            end
          end
        else
          ws.send %(["OK","#{data.event.id}",false,"invalid: signature"])
        end
      when Nostr::RequestMessage
        client.subscribe(data.sub_id, data.filters)
      when Nostr::CountMessage
        count = DB.count(data.filters)
        ws.send %(["COUNT","#{data.sub_id}",{"count":#{count}}])
      when Nostr::CloseMessage
        client.unsubscribe(data.sub_id)
      else
        raise "unknown message type: #{data}"
      end
    rescue error
      Log.error { "Error processing message: #{error.message}" }
      ws.send(["NOTICE", error.message].to_json)
    end
  end

  ws.on_close do
    client.close
    Log.info { "Client disconnected" }
  end
end

server = HTTP::Server.new([
  HTTP::ErrorHandler.new,
  HTTP::LogHandler.new,
  websocket_handler,
  RelayHandler.new,
])

address = server.bind_tcp "0.0.0.0", 8080
puts "Relay listening on ws://#{address}/"
puts "NIP-11 info: http://#{address}/ (with Accept: application/nostr+json)"
puts "Static files: http://#{address}/"

server.listen
