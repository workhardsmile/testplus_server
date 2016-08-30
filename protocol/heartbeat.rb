module Marquee
  module Protocol
    class Heartbeat
      def execute(server, connection)
        server.client_heartbeat(self, connection)
      end
    end
  end
end
