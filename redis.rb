require 'redis'
require 'yaml'
redis_config_all = YAML::load(File.open("#{File.dirname(__FILE__)}/redis.yml"))
env_name = ENV['RAILS_ENV'] || "development"

$redis = Redis.new(redis_config_all[env_name])