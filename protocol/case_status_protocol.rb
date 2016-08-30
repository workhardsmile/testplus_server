module Marquee
  module Protocol
    class CaseStatusProtocol
      attr_accessor :round_id
      attr_accessor :script_name
      attr_accessor :case_id
      attr_accessor :status
      attr_accessor :description
      attr_accessor :screen_shot
      attr_accessor :server_log

      def execute(server, connection)
        server.update_case_result(self, connection)
      end

    end
  end
end
