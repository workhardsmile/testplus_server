require "rubygems"
require "state_machine"
require "test/unit"
require "#{File.dirname(__FILE__)}/model"

class SlaveTest < Test::Unit::TestCase
  def setup
    @slave = Slave.create
    @slave.save
  end

  def teardown
    @slave.delete
  end

  def test_slave_offline
    @slave.come_online(2)
    @slave.go_offline
    assert !@slave.free?
    assert_nil @slave.connection
    assert_nil @slave.assignment
    assert !@slave.go_offline
  end

  def test_slave_initial_state
    assert @slave.offline?
  end

  def test_slave_state_transition
    @slave.come_online
    @slave.start_assignment
    assert @slave.busy?

    @slave.finish_assignment
    assert @slave.free?

    @slave.start_assignment
    assert @slave.busy?
    @slave.stop_assignment
    assert @slave.free?
  end

  def test_slave_transition_error
    # not online slave shouldn't start assignment
    assert !@slave.start_assignment

    @slave.come_online
    @slave.start_assignment
    assert !@slave.start_assignment
  end

  def test_online
    @slave.come_online(2)
    assert_equal 2, @slave.connection
    assert @slave.free?
  end

  def test_assignment
    @slave.come_online(2)
    @slave.start_assignment(3)
    assert_equal 3, @slave.assignment
  end
end
