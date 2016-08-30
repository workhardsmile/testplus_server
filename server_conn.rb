require 'rubygems'
require 'eventmachine'
require "socket"
require "yaml"

YAML::ENGINE.yamler = 'syck'

class ServerConn < EM::Connection
  def receive_data data # :nodoc:
    (@buf ||= '') << data
    while @buf.size >= 4
      if @buf.size >= (size=@buf.unpack('N').first)
        @buf.slice!(0,4)
        receive_object serializer.load(@buf.slice!(0,size))
      else
        break
      end
    end
  end

  # Sends a ruby object over the network
  def send_object obj
    data = serializer.dump(obj)
    send_data [data.respond_to?(:bytesize) ? data.bytesize : data.size, data].pack('Na*')
  end

  def serializer
    YAML
  end

  def get_ip_address
    port, ip = Socket.unpack_sockaddr_in(get_peername)
    ip
  end

  def set_server(server)
    @server = server
  end

  def receive_object(obj)
    obj.execute(@server, self)
  end

  def unbind
    @server.remove_client(self)
  end
end
