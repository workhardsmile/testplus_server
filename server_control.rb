require "rubygems"
require "daemons"

Daemons.run("#{File.dirname(__FILE__)}/server.rb")