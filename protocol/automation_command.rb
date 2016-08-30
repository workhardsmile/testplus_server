module Marquee
  module Protocol
    class AutomationCommand
      attr_accessor :driver
      attr_accessor :slave_id
      attr_accessor :slave_assignment_id
      attr_accessor :timeout_limit
      attr_accessor :test_round_id
      attr_accessor :script_name
      attr_accessor :environment
      attr_accessor :test_type
      attr_accessor :checkout_paths
      attr_accessor :version_tool
      attr_accessor :test_case_path
      attr_accessor :sc_username
      attr_accessor :sc_password
      attr_accessor :browser_name
      attr_accessor :browser_version
      attr_accessor :branch_name
      attr_accessor :parameter

      def initialize(assignment)
        slave = assignment.slave
        automation_driver_config = assignment.automation_script.automation_driver_config

        self.driver = automation_driver_config.automation_driver.name
        self.timeout_limit = assignment.time_out_limit * 1000
        self.test_case_path = automation_driver_config.script_main_path
        self.test_round_id = assignment.test_round.id
        self.branch_name = assignment.test_round.branch_name 
        self.parameter = assignment.test_round.parameter
        self.script_name = assignment.automation_script.name
        self.environment = assignment.test_round.test_environment.value
        self.test_type = assignment.test_round.test_suite.test_type.name
        self.slave_id = slave.id
        self.slave_assignment_id = assignment.id
        self.version_tool = automation_driver_config.source_control
        self.sc_username = automation_driver_config.sc_username
        self.sc_password = automation_driver_config.sc_password
        self.browser_name = assignment.browser_name
        self.browser_version = assignment.browser_version
        self.checkout_paths = {}
        JSON.parse(automation_driver_config.source_paths).each do |paths|
          self.checkout_paths[paths['local']] = paths['remote']
        end
      end
    end
  end
end
