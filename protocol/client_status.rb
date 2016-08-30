module Marquee
  module Protocol
    class ClientStatus
      attr_accessor :status
      attr_accessor :slave_id
      attr_accessor :slave_assignment_id

      def execute(server, connection)
        server.update_client_status(self, connection)
      end
    end
  end
end
