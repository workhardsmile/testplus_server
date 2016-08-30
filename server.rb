require "rubygems"
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __FILE__)
require "bundler/setup" if File.exists?(ENV['BUNDLE_GEMFILE'])

require "eventmachine"
require "rest_client"
require "#{File.dirname(__FILE__)}/redis"
require "#{File.dirname(__FILE__)}/server_conn"
require "#{File.dirname(__FILE__)}/model"
require "#{File.dirname(__FILE__)}/protocol/client_info"
require "#{File.dirname(__FILE__)}/protocol/client_status"
require "#{File.dirname(__FILE__)}/protocol/automation_command"
require "#{File.dirname(__FILE__)}/protocol/heartbeat"
require "#{File.dirname(__FILE__)}/protocol/script_status_protocol"
require "#{File.dirname(__FILE__)}/protocol/case_status_protocol"
require "#{File.dirname(__FILE__)}/slave_manager"
require "#{File.dirname(__FILE__)}/logger"

class Server
  attr_accessor :logger
  attr_accessor :connections
  attr_accessor :slave_manager

  def initialize
    @logger = Marquee::Log.new("#{File.dirname(__FILE__)}/log/farm_server.log")
    @connections = []
    logger.info "Farm Server start initializing..."
    @slave_manager = SlaveManager.new
    logger.info "Farm Server Successfully initialized"
  end

  def start
    trap('INT'){stop}
    trap('TERM'){stop}
    logger.info "Farm Server started"

    @signature = EventMachine.start_server('0.0.0.0', 9527, ServerConn) do |conn|
      logger.info "Farm Server got a new connection"
      conn.set_server(self)
    end

    EventMachine::PeriodicTimer.new(5) do
      # iterate through connections see whether there's long-ideling connections
      @connections.each do |conn|
        if !is_connection_associated_with_slave(conn)
          logger.info "Found a connection not associated with a slave, close it."
          conn.close
          @connections.delete(conn)
        end
      end
      slave_manager.update_slave_list
      slave_manager.slave_keep_alive
      slave_manager.clear_timeout_assignments
      slave_manager.stop_requested_assignments
      slave_manager.schedule_assignments
    end
  rescue => e
    logger.fatal e.message
    stop
  end

  def update_client_status(client_status, connection)
    slave_manager.update_slave_status(client_status)
  end

  # called when a slave come online
  def add_or_update_client(client_info, connection)
    slave_manager.new_slave_connection(client_info, connection)
  end

  def client_heartbeat(heartbeat, connection)
    slave_manager.update_slave_heartbeat(connection)
    connection.send_object Marquee::Protocol::Heartbeat.new
  end

  def update_case_result(case_result, connection)
    # just forward to webserver in order to calculate the results
    data = {
      :protocol => {
        :what => 'Case',
        :round_id => case_result.round_id,
        :data => {
          :script_name => case_result.script_name,
          :case_id => case_result.case_id,
          :result => case_result.status,
          :error => case_result.description,
          :screen_shot => case_result.screen_shot,
          :server_log => case_result.server_log
        }
      }
    }
    logger.info "update case result: #{data}"
    begin
      RestClient.post "#{WebServerBase}/status/update", data
    rescue => e
      logger.error "post case result to web server failed: #{e}"
    end
  end

  def update_script_status(script_status, connection)
    # first, we update slave and assignment status
    # todo:
    slave_manager.update_slave_status(connection, script_status)

    # here, we only manage the slave and assignments status, and just forward the parameters to webserver in order to calculate the results
    data = {
      :protocol => {
        :what => 'Script',
        :round_id => script_status.round_id,
        :data => {
          :script_name => script_status.script_name,
          :state => script_status.status,
          'service' => {
            '' => script_status.services_as_json
          }
        }
      }
    }

    logger.info "update script status: #{data}"
    begin
      RestClient.post "#{WebServerBase}/status/update", data
    rescue => e
      logger.error "post script result to web server failed: #{e}"
    end
  end

  # called when a client connection closed
  def remove_client(conn)
    slave_manager.slave_connection_lost(conn)
    @connections.delete(conn)
  end

  def stop
    logger.info 'Server#stop'
    EventMachine.stop_server(@signature)
    EventMachine.stop
  end

end

EventMachine::run{
  Server.new.start
}
