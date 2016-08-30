require 'active_record'
require 'rest_client'

require "#{File.dirname(__FILE__)}/logger"
require "#{File.dirname(__FILE__)}/db_conn"

# == Schema Information
#
# Table name: slaves
#
#  id           :integer         not null, primary key
#  name         :string(255)
#  ip_address   :string(255)
#  project_name :string(255)
#  created_at   :datetime
#  updated_at   :datetime
#  status       :string(255)
#
class Slave < ActiveRecord::Base
  default_scope :include => [:capabilities, :operation_system_info]
  has_one :operation_system_info
  has_many :capabilities
  has_many :slave_assignments
  has_many :automation_script_results, :through => :slave_assignments

  attr_accessor :connection
  attr_accessor :assignment
  attr_accessor :last_heartbeat

  def self.authenticate(client_info)
    Slave.find_by_name(client_info.name)
  end

  def free?
    status == 'free'
  end

  def free!
    self.status = 'free'
    self.save!
  end

  def come_online(connection, info, assignment)
    self.clear_slave_info
    self.connection = connection
    self.ip_address = self.connection.get_ip_address

    [info.automation_drivers, info.browsers, info.version_tools, info.operation_system].flatten.each do |cap|
      self.capabilities.build(name: cap.name, version: cap.version)
    end
    self.last_heartbeat = Time.now

    # if info.status == 'running'
    #   self.assignment = assignment
    #   start_assignment
    # else
    #   self.status = "free"
    # end
    if info.status == 'idle'
      self.status = "free"
    else
      self.status = 'busy'
    end
    save!
  end

  def go_offline
    self.ip_address = ""
    self.connection = nil
    self.assignment = nil
    self.status = 'offline'
    self.save!
  end

  def stop_assignment
    connection.send_object(Marquee::Protocol::StopSlave.new)
  end

  def clear_slave_info
    operation_system_info.delete unless operation_system_info.nil?
    capabilities.delete_all
  end
end

# == Schema Information
#
# Table name: slave_assignments
#
#  id                          :integer         not null, primary key
#  automation_script_result_id :integer
#  slave_id                    :integer
#  status                      :string(255)
#  created_at                  :datetime
#  updated_at                  :datetime
#  driver                      :string(255)
#
class SlaveAssignment < ActiveRecord::Base
  belongs_to :automation_script_result
  belongs_to :slave

  def kill!
    result = {
      :protocol => {
        :what => "Script",
        :round_id => test_round.id, 
        :data => {
          :script_name => automation_script.name, 
          :state => "killed"
        }
      }
    }
    RestClient.post( "#{WebServerBase}/status/update  ", result)
    # self.status = 'killed'
    # self.save!
    # asr = automation_script_result
    # asr.state = "killed"
    # asr.result = "failed"
    # asr.update_end_time
    # asr.save!
    # test_round.update_on_finish
  rescue => e
    e.response
  end

  def automation_script
    automation_script_result.automation_script
  end

  def test_round
    automation_script_result.test_round
  end

  def time_out_limit
    self.automation_script.time_out_limit.nil? ? 7200 : self.automation_script.time_out_limit
  end

  def end!
    self.status = "complete"
    save
  end

  def as_json(options={})
    {
      id: self.id,
      slave_id: self.slave.nil? ? nil : self.slave.id,
      time_out_limit: time_out_limit,
      created_at: self.created_at,
      updated_at: self.updated_at
    }
  end

end

class AutomationDriver < ActiveRecord::Base
end

class AutomationDriverConfig < ActiveRecord::Base
  has_many :automation_scripts
  belongs_to :automation_driver
end

# == Schema Information
#
# Table name: operation_system_infos
#
#  id         :integer         not null, primary key
#  name       :string(255)
#  version    :string(255)
#  slave_id   :integer
#  created_at :datetime
#  updated_at :datetime
#
class OperationSystemInfo < ActiveRecord::Base
  belongs_to :slave
end

# == Schema Information
#
# Table name: capabilities
#
#  id         :integer         not null, primary key
#  name       :string(255)
#  version    :string(255)
#  slave_id   :integer
#  created_at :datetime
#  updated_at :datetime
#
class Capability < ActiveRecord::Base
  belongs_to :slave
end

# == Module Definition
#
#  Module name: CounterUpdatable
module CounterUpdatable

end

# == Schema Information
#
# Table name: automation_script_results
#
#  id                   :integer         not null, primary key
#  state                :string(255)
#  pass                 :integer
#  failed               :integer
#  warning              :integer
#  not_run              :integer
#  result               :string(255)
#  start_time           :datetime
#  end_time             :datetime
#  test_round_id        :integer
#  automation_script_id :integer
#  created_at           :datetime
#  updated_at           :datetime
#
class AutomationScriptResult < ActiveRecord::Base
  include CounterUpdatable
  belongs_to :test_round
  belongs_to :automation_script
  has_many :automation_case_results
  has_many :target_services
  has_many :slave_assignments
  has_many :slaves, :through => :slave_assignments

  delegate :name, :to => :automation_script, :prefix => false

  def update_end_time
    if self.start_time.blank?
      self.start_time = Time.now
    end
    self.end_time = Time.now
  end

  def end?
    self.state == 'end' or self.state == 'done' or self.state == 'killed' or self.state == 'timeout' or self.state == 'not implemented' or self.state == 'network issue'
  end

  def passed?
    self.result == "pass"
  end
end


# == Schema Information
#
# Table name: test_rounds
#
#  id                  :integer         not null, primary key
#  start_time          :datetime
#  end_time            :datetime
#  state               :string(255)
#  result              :string(255)
#  test_object         :string(255)
#  pass                :integer
#  warning             :integer
#  failed              :integer
#  not_run             :integer
#  pass_rate           :float
#  duration            :integer
#  triage_result       :string(255)
#  test_environment_id :integer
#  project_id          :integer
#  creator_id          :integer
#  test_suite_id       :integer
#  created_at          :datetime
#  updated_at          :datetime
#
class TestRound < ActiveRecord::Base
  include CounterUpdatable
  belongs_to :test_environment
  belongs_to :project
  belongs_to :test_suite
  belongs_to :creator, :class_name => "User", :foreign_key => "creator_id"
  has_many :automation_script_results

  delegate :automation_case_count, :to => :test_suite, :prefix => false
  delegate :test_type, :to => :test_suite, :prefix => false

  validates_presence_of :test_object

  def to_s
    "#{self.test_type.name} ##{self.id}"
  end

  def update_on_finish
    reload
    if all_automation_script_results_finished?
      calculate_result!
      calculate_pass_rate!
      calculate_result!
      update_end_time
      save!
    end
  end

  def update_end_time
    self.end_time = automation_script_results.collect{|asr| asr.end_time.nil? ? Time.now : asr.end_time}.max
    self.duration = 7200  # => Set duration default to 7200
    self.duration = self.end_time - self.start_time if self.end_time && self.start_time && self.end_time > self.start_time
  end

  def update_start_time
    reload
    self.start_time = self.automation_script_results.collect{|asr| asr.start_time.nil? ? Time.now : asr.start_time}.min
  end

  def all_automation_script_results_finished?
    automation_script_results.all?{|asr| asr.end?}
  end

  def calculate_result!
    if automation_script_results.all?{|asr| asr.automation_script.not_implemented? }
      self.state = 'not implemented'
      self.result = 'N/A'
      # elsif automation_script_results.all?{|asr| asr.service_error?}
      # self.state = 'service error'
      # self.result = 'N/A'
    elsif automation_script_results.all?{|asr| asr.passed?}
      self.state = 'completed'
      self.result = 'pass'
    else
      self.state = 'completed'
      self.result = 'failed'
    end
  end

  def calculate_duration!
    self.duration = end_time - start_time
  end

  def pass_count
    self.automation_script_results.sum(:pass)
  end

  def calculate_pass_rate!
    if automation_case_count == 0
      0.0
    else
      self.pass_rate = (pass_count.to_f * 100)/ automation_case_count
      self.pass_rate.round(2)
    end
  end
end

# == Schema Information
#
# Table name: projects
#
#  id                      :integer         not null, primary key
#  name                    :string(255)
#  leader_id               :integer
#  project_category_id     :integer
#  source_control_path     :string(255)
#  icon_image_file_name    :string(255)
#  icon_image_content_type :string(255)
#  icon_image_file_size    :integer
#  state                   :string(255)
#  created_at              :datetime
#  updated_at              :datetime
#
class Project < ActiveRecord::Base
  belongs_to :project_category
  belongs_to :leader, :class_name => "User", :foreign_key => "leader_id"
  has_many :test_plans
  has_many :automation_scripts
  has_many :test_suites
  has_many :test_rounds
  has_many :ci_mappings
  has_many :mail_notify_settings
  # has_attached_file :icon_image, :processors => [:cropper], :styles => { :large => "320x320", :medium => "180x180>", :thumb => "100x100>" }, :path => ":rails_root/public/images/projects/:style_:basename.:extension", :url => "/images/projects/:style_:basename.:extension"

  attr_accessor :crop_x, :crop_y, :crop_w, :crop_h
  after_update :reprocess_icon_image, :if => :cropping?

  def to_s
    self.name
  end

  def cropping?
    !crop_x.blank? && !crop_y.blank? && !crop_w.blank? && !crop_h.blank?
  end

  private

  def reprocess_icon_image
    icon_image.reprocess!
  end

end

# == Schema Information
#
# Table name: automation_scripts
#
#  id                   :integer         not null, primary key
#  name                 :string(255)
#  status               :string(255)
#  version              :string(255)
#  test_plan_id         :integer
#  owner_id             :integer
#  project_id           :integer
#  created_at           :datetime
#  updated_at           :datetime
#  automation_driver_id :integer
#  time_out_limit       :integer
#
class AutomationScript < ActiveRecord::Base
  belongs_to :test_plan
  belongs_to :project
  belongs_to :owner, :class_name => "User", :foreign_key => "owner_id"
  has_many :automation_cases
  has_many :suite_selections
  has_many :test_suites, :through => :suite_selections
  belongs_to :automation_driver_config

  def not_implemented?
    self.status == "not implemented"
  end
end

# == Schema Information
#
# Table name: test_environments
#
#  id         :integer         not null, primary key
#  name       :string(255)
#  value      :string(255)
#  created_at :datetime
#  updated_at :datetime
#
class TestEnvironment < ActiveRecord::Base

  def to_s
    self.name
  end
end

# == Schema Information
#
# Table name: test_suites
#
#  id           :integer         not null, primary key
#  name         :string(255)
#  status       :string(255)
#  project_id   :integer
#  creator_id   :integer
#  test_type_id :integer
#  created_at   :datetime
#  updated_at   :datetime
#
class TestSuite < ActiveRecord::Base
  belongs_to :project
  belongs_to :test_type
  belongs_to :creator, :class_name => "User", :foreign_key => "creator_id"
  has_many :suite_selections
  has_many :automation_scripts, :through => :suite_selections
  has_many :test_rounds
  has_many :ci_mappings

  def automation_case_count
    self.automation_scripts.inject(0){|count,as| count + as.automation_cases.count}
  end
end

# == Schema Information
#
# Table name: test_types
#
#  id   :integer         not null, primary key
#  name :string(255)
#
class TestType < ActiveRecord::Base
  has_many :test_suites
  has_and_belongs_to_many :mail_notify_settings
end

# == Schema Information
#
# Table name: suite_selections
#
#  test_suite_id        :integer
#  automation_script_id :integer
#  created_at           :datetime
#  updated_at           :datetime
#

class SuiteSelection < ActiveRecord::Base
  belongs_to :test_suite
  belongs_to :automation_script
end

# == Schema Information
#
# Table name: automation_cases
#
#  id                   :integer         not null, primary key
#  name                 :string(255)
#  case_id              :string(255)
#  version              :string(255)
#  priority             :string(255)
#  automation_script_id :integer
#  created_at           :datetime
#  updated_at           :datetime
#

class AutomationCase < ActiveRecord::Base
  belongs_to :automation_script
  has_many :automation_case_results
end
