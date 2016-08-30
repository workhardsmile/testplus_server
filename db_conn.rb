ActiveRecord::Base.logger = Marquee::Log.new("#{File.dirname(__FILE__)}/log/farm_server.log")
logger = Marquee::Log.new("#{File.dirname(__FILE__)}/log/farm_server.log")

db_config_all = YAML::load(File.open("#{File.dirname(__FILE__)}/db_conn.yml"))
env_name = ENV['RAILS_ENV']
if (env_name && db_config_all.has_key?(env_name))
  db_config = db_config_all.fetch(env_name)
  logger.info "Connecting to #{env_name}."
else
  db_config = db_config_all.fetch("development")
  error_msg = "Can't find environment definition for #{env_name.nil? ? "nil" : env_name}. Using development as default."
  puts error_msg
  logger.error error_msg
end

ActiveRecord::Base.establish_connection db_config
ActiveRecord::Base.default_timezone = :utc

config = YAML::load(File.open("#{File.dirname(__FILE__)}/config.yml"))
WebServerBase = config['webserver']
puts WebServerBase
