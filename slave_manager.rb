require "#{File.dirname(__FILE__)}/model"
require "#{File.dirname(__FILE__)}/logger"
require "#{File.dirname(__FILE__)}/protocol/unauthorized_slave"
require "#{File.dirname(__FILE__)}/protocol/stop_slave"

class SlaveManager
  attr_reader :slaves
  attr_accessor :assignments
  attr_accessor :logger

  def initialize
    @assignments = []
    load_not_finish_assignments_from_db
    @logger = Marquee::Log.new("#{File.dirname(__FILE__)}/log/farm_server.log")
    logger.info "AssignmentManager pre load #{@assignments.count} un finished assignments from Database"

    @slaves = []
    Slave.all.each do |slave|
      slave.ip_address = ""
      slave.status = 'offline'
      slave.save
    end
  end

  def is_connection_associated_with_slave(connection)
    @slaves.each do |slave|
      if @slave.connection == connection
        return true
      end
    end
    return false
  end

  def update_slave_list
    $redis.scard("slaves_to_be_updated").times do
      slave_id_to_be_updated = $redis.spop("slaves_to_be_updated").to_i
      slave = Slave.find_by_id slave_id_to_be_updated
      if slave
        logger.info "Slave #{slave.name} is created/updated from marquee. Updating slave in list now."
        @slaves.each do |tmp_slave|
          if tmp_slave.id == slave_id_to_be_updated
            if tmp_slave.name == slave.name # if slave name is not changed, just update other information
              tmp_slave.project_name = slave.project_name
              tmp_slave.test_type = slave.test_type
              tmp_slave.priority = slave.priority
              tmp_slave.active = slave.active
            else # if slave name is changed, just remove it.
              logger.info "Name of slave id:#{slave_id_to_be_updated} is changed from #{tmp_slave.name} to #{slave.name}. Removing from slave list now."
              @slaves.delete tmp_slave
            end
            break
          end
        end
      else
        logger.info "Slave id:#{slave_id_to_be_updated} is removed from marquee. Removing from slave list now."
        @slaves.reject! {|tmp_slave| tmp_slave.id == slave_id_to_be_updated}
      end
    end
  end

  def slave_keep_alive
    timeout_slaves = []
    @slaves.each do |slave|
      if (Time.now - slave.last_heartbeat) > 20
        logger.info "Found a timeout slave: #{slave.inspect}, will close connection."
        slave.connection.close_connection
        slave.go_offline
        timeout_slaves << slave
      end
    end
    timeout_slaves.each do |slave|
      @slaves.delete(slave)
    end
  end

  def update_slave_heartbeat(connection)
    @slaves.each do |slave|
      if slave.connection == connection
        slave.last_heartbeat = Time.now
      end
    end
  end

  def new_slave_connection(client_info, connection)
    # search through database to find the authenticated slave
    slave = Slave.authenticate(client_info)
    if slave.nil?
      logger.error "An unauthorized slave: [#{client_info.name}] trying to connect to Farm Server, close it"
      connection.send_object(Marquee::Protocol::UnauthorizedSlave.new)
      return false
    else
      logger.info "A slave: [#{client_info.name}] connected"
      logger.debug "client info from slave [#{client_info.name}]: #{client_info.inspect}"
      @slaves << slave
      # slave.come_online(connection, client_info, find_assignment(client_info.assignment_id))
      slave.come_online(connection, client_info, nil)
      return true
    end
  end

  def update_slave_status(connection, script_status)
    slave = find_slave_by_connection(connection)
    status = script_status.status
    # assignment = slave.assignment

    # we'll look through all assignments in memory to see which one is for this
    assignment = find_assignment_by_test_round_and_script_name(script_status.round_id, script_status.script_name)

    if assignment.nil?
      logger.error "Get slave status update for a script #{script_status.script_name} for round: #{script_status.round_id}, but couldn't find an assignment, anyway will update slave status"
      unless status == 'running'
        slave.status = 'free'
        slave.save!
      end
    else
      if status == 'running'
        logger.info "Assignment #{assignment.id}, script name: [#{script_status.script_name}], on slave [#{slave.name}] start running"
        assignment.status = 'running'
        assignment.save!
        assignment.automation_script_result.start_time = Time.now if assignment.automation_script_result.start_time.blank?
        assignment.automation_script_result.save!
        assignment.test_round.update_start_time
        assignment.test_round.save!
        slave.status = 'busy'
        slave.save!
      elsif status == 'done'
        logger.info "Assignment #{assignment.id}, script name: [#{script_status.script_name}], on slave [#{slave.name}] done"
        assignment.reload
        if assignment.status != 'complete' and assignment.status != 'killed'
          assignment.status = 'complete'
          assignment.save!
        end
        slave.free!
        @assignments.delete(assignment)
      elsif status == 'killed'
        logger.info "Assignment #{assignment.id}, script name: [#{script_status.script_name}], on slave [#{slave.name}] killed"
        assignment.kill!
        slave.free!
        logger.info "Assignment killed. slave state: #{slave.status}"
        @assignments.delete(assignment)
      elsif status == 'timeout'
        logger.info "Assignment #{assignment.id}, script name: [#{script_status.script_name}], on slave [#{slave.name}] killed"
        assignment.kill!
        slave.free!
        logger.info "Assignment killed. slave state: #{slave.status}"
        @assignments.delete(assignment)
      elsif status == 'failed'
        logger.info "Assignment #{assignment.id}, script name: [#{script_status.script_name}], on slave [#{slave.name}] failed, error: #{script_status.description}"
        assignment.reload
        if assignment.status != 'complete' and assignment.status != 'killed'
          assignment.status = 'complete'
          assignment.save!
        end
        slave.free!
        @assignments.delete(assignment)
      end
    end
  end

  def slave_connection_lost(connection)
    @slaves.each do |slave|
      if slave.connection == connection
        logger.info "A slave #{slave.name} goes offline because connection lost"
        slave.go_offline
        @slaves.delete(slave)
        break
      end
    end
  end

  def schedule_assignments
    pending_assignments do |assignment|
      schedule_assignment(assignment)
    end
  end

  def clear_timeout_assignments
    assignments_to_delete = []
    @assignments.each do |assignment|
      if assignment.status == 'running' or assignment.status == 'assigned'
        if time_out?(assignment)
          if assignment.slave && assignment.slave.assignment == assignment
            logger.info "Assignment #{assignment.id}, script name: [#{assignment.automation_script.name}] on slave [#{assignment.slave.name}] timeout, kill it."
            assignment.kill!
            # todo: how to deal with slave?
          else
            assignment.kill!
            assignments_to_delete << assignment
          end
        end
      end
    end
    assignments_to_delete.each{|a| @assignments.delete(a)}
  end

  def stop_requested_assignments
    sa_list = $redis.hget :slave_assignments, 'stop'
    $redis.hset :slave_assignments, 'stop', JSON.generate([])
    unless sa_list.nil?
      JSON.parse(sa_list).each do |sa|
        slaves = find_slaves_by_id(sa['slave_id'])
        assignment = SlaveAssignment.find(sa['id'])

        #assignment.kill!
        if slaves.empty?
          logger.info "got instruction to stop a test (no slave found) - assignment: [#{assignment.id}], script: [#{assignment.automation_script.name}]"
          # assignment.kill!
        else
          slaves.each do |slave|
            if !slave.assignment.nil? and !assignment.nil? and slave.assignment.id == assignment.id
              logger.info "got instruction to stop a test (slave found) - assignment: [#{assignment.id}], script name: [#{assignment.automation_script.name}], slave name: [#{slave.name}]"
              slave.stop_assignment
            else
              logger.info "got instruction to stop a test (slave found but wrong assignment) - assignment: [#{assignment.id}], script name: [#{assignment.automation_script.name}], slave name: [#{slave.name}], will anyway send instruction to this slave"
              # assignment.kill!
              # slave.stop_assignment
            end
          end
        end
      end
    end
  end
  protected
  def pending_assignments
    # first, we check the redis see whether there's new assignment there
    get_new_assignment_from_redis
    @assignments.each do |assignment|
      if assignment.status == 'pending'
        yield assignment
      end
    end
  end

  def load_not_finish_assignments_from_db
    SlaveAssignment.find_all_by_status('pending').each do |assignment|
      @assignments << assignment
    end
    SlaveAssignment.find_all_by_status('assigned').each do |assignment|
      @assignments << assignment
    end
    SlaveAssignment.find_all_by_status('running').each do |assignment|
      @assignments << assignment
    end
  end

  def find_assignment(id)
    @assignments.find{|a| a.id == id}
  end

  def schedule_assignment(assignment)
    project_name = assignment.test_round.project.name
    test_type_name = assignment.test_round.test_suite.test_type.name
    driver_config = assignment.automation_script.automation_driver_config
    capabilities = [assignment.operation_system_name, assignment.browser_name]
    assigned_slave_id = assignment.test_round.assigned_slave_id
    slave = nil
    if assigned_slave_id == 0
      #run test on any available slaves
      slave = find_best_suite_slave_new(project_name, test_type_name, driver_config, capabilities) if driver_config
    else
      #run test on the assigne slave when it is free
      slave = find_assigned_slave_by_id(assigned_slave_id, driver_config, capabilities) if driver_config
    end

    if slave
      logger.info "Found a slave [#{slave.name}]to execute the assignment #{assignment.id}, script name: [#{assignment.automation_script.name}]"

      assignment.status = 'assigned'
      assignment.slave = slave
      assignment.save!
      slave.assignment = assignment
      slave.connection.send_object(Marquee::Protocol::AutomationCommand.new(assignment))
      slave.status = 'assigned'
      slave.save!
    else
      logger.debug "No slave found for assignment #{assignment.id}, script name: [#{assignment.automation_script.name}]"
    end
  end

  def capability_match?(slave, capabilities)
    capabilities & slave.capabilities.collect{|c|c.name} == capabilities
  end

  def find_best_suite_slave(project_name, driver_config, capabilities)
    candidate = nil
    @slaves.each do |slave|
      next if !slave.free?
      if slave.project_name == project_name
        candidate = slave if capability_match?(slave, [driver_config.automation_driver.name] + capabilities)
        break if candidate
      end
    end

    unless candidate
      @slaves.each do |slave|
        next if !slave.free?
        if slave.project_name.split(',').index(project_name)
          candidate = slave if capability_match?(slave, [driver_config.automation_driver.name] + capabilities)
          break if candidate
        end
      end
    end

    unless candidate
      @slaves.each do |slave|
        next if !slave.free?
        if slave.project_name == "*"
          candidate = slave if capability_match?(slave, [driver_config.automation_driver.name] + capabilities)
          break if candidate
        end
      end
    end

    candidate
  end

  def find_best_suite_slave_new(project_name, test_type_name, driver_config, capabilities)

    candidate = nil

    ordered_candidates = Array.new
    @slaves.each do |slave|
      next if !slave.free? or !slave.active
      ordered_candidates << slave if (slave.project_name == project_name or slave.project_name.split(',').index(project_name) or slave.project_name == "*") and (slave.test_type == test_type_name or slave.test_type.include?(test_type_name) or slave.test_type == "*")
    end

    ordered_candidates.sort! &slave_sorter(project_name, test_type_name)

    ordered_candidates.each do |slave|
      candidate = slave if capability_match?(slave, [driver_config.automation_driver.name] + capabilities)
      break if candidate
    end

    candidate
  end


  def find_assigned_slave_by_id(assigned_slave_id, driver_config, capabilities)
    slave = nil
    @slaves.each do |s|
      if s.id == assigned_slave_id 
        slave = s
        break
      end
    end
    if slave and slave.free?
      return slave if capability_match?(slave, [driver_config.automation_driver.name] + capabilities)
    end
    nil
  end

  def slave_sorter(project_name, test_type_name)

    lambda do |x, y|
      # exact project < multiple project < *
      if x.project_name != y.project_name
        if x.project_name == project_name or y.project_name == "*"
          return -1
        elsif x.project_name == "*" or y.project_name == project_name
          return 1
        end
      end
      # exact test_type < multiple test_type < *
      if x.test_type != y.test_type
        if x.test_type == test_type_name or y.test_type == "*"
          return -1
        elsif x.test_type == "*" or y.test_type == test_type_name
          return 1
        end
      end
      # priority
      x.priority <=> y.priority
    end

  end

  def find_slaves_by_id(id)
    @slaves.select{|s| s.id == id}
  end

  def find_slave_by_connection(connection)
    results = @slaves.select{|s| s.connection == connection}
    if results.empty?
      nil
    else
      results[0]
    end
  end

  def find_assignment_by_test_round_and_script_name(round_id, script_name)
    result = nil
    @assignments.each do |assignment|
      if assignment.automation_script.name == script_name and assignment.automation_script_result.test_round.id == round_id
        result = assignment
        break
      end
    end
    result
  end

  def get_new_assignment_from_redis
    sa_list = $redis.hget :slave_assignments, 'pending'
    $redis.hset :slave_assignments, 'pending', JSON.generate([])
    unless sa_list.nil?
      JSON.parse(sa_list).each do |sa|
        assignment = SlaveAssignment.find(sa['id'])
        @assignments << assignment unless assignment.nil?
      end
    end
  end

  def time_out?(assignment)
    time_out_limit = assignment.time_out_limit
    time_out_limit = 2*3600 if time_out_limit.nil?
    time_start = assignment.updated_at

    if Time.now - time_start > time_out_limit
      return true
    else
      return false
    end
  end
end
