module Marquee
  module Protocol
    class Service
      attr_accessor :name
      attr_accessor :version
    end

    class ScriptStatusProtocol
      attr_accessor :round_id
      attr_accessor :script_name
      attr_accessor :slave_status
      attr_accessor :status
      attr_accessor :description
      attr_accessor :services

      def initialize
        self.services = []
      end

      def execute(server, connection)
        server.update_script_status(self, connection)
      end

      def services_as_json
        result = []
        unless services.nil?
          services.each do |s|
            result << {'name' => s.name, 'version' => s.version}
          end
        end
        result
      end
    end
  end
end
