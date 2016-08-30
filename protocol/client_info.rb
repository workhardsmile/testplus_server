module Marquee
  module Protocol
    class OperationSystem
      attr_accessor :name
      attr_accessor :version
    end

    class Browser
      attr_accessor :name
      attr_accessor :version
    end

    class VersionTool
      attr_accessor :name
      attr_accessor :version
    end

    class AutomationDriver
      attr_accessor :name
      attr_accessor :version
    end

    class ClientInfo
      attr_accessor :name
      attr_accessor :operation_system
      attr_accessor :automation_drivers
      attr_accessor :version_tools
      attr_accessor :browsers
      attr_accessor :status
      attr_accessor :assignment_id

      def initialize
        @automation_drivers = []
        @version_tools = []
        @browsers = []
      end

      def execute(server, connection)
        server.add_or_update_client(self, connection)
      end
    end

  end
end
