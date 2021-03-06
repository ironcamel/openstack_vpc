require File.dirname(__FILE__) + '/helper'
require 'tempfile'

class TestServers < Test::Unit::TestCase

  def setup
    @conn=Helper::get_connection
    @image_id = Helper::get_last_image_id(@conn)
    @servers = []
    @images = []
  end

  def teardown
    @servers.each do |server|
      assert_equal(true, server.delete!)
    end
    @images.each do |image|
      assert_equal(true, image.delete!)
    end
  end

  def ssh_test(ip_addr)
    begin
      Timeout::timeout(SSH_TIMEOUT) do

        while(1) do
          ssh_identity=SSH_PRIVATE_KEY
          if KEYPAIR and not KEYPAIR.empty? then
              ssh_identity=KEYPAIR
          end
          if system("ssh -o StrictHostKeyChecking=no -i #{ssh_identity} root@#{ip_addr} /bin/true > /dev/null 2>&1") then
            return true
          end
        end

      end
    rescue Timeout::Error => te
      fail("Timeout trying to ssh to server: #{ip_addr}")
    end

    return false

  end

  def ping_test(ip_addr)
    begin
      Timeout::timeout(PING_TIMEOUT) do

        while(1) do
          if system("ping -c 1 #{ip_addr} > /dev/null 2>&1") then
            return true
          end
        end

      end
    rescue Timeout::Error => te
      fail("Timeout pinging server: #{ip_addr}")
    end

    return false

  end

  def create_server(server_opts)
    server = @conn.create_server(server_opts)
    @servers << server
    server
  end

  def create_image(server, image_name)
    image = server.create_image(image_name)
    @images << image
    image
  end

  def check_server(server, image_id, flavor_id, check_status="ACTIVE")

    assert_not_nil(server.hostId)
    assert_equal(flavor_id, server.flavorId)
    assert_equal(image_id, server.imageId.to_s)
    assert_equal('test1', server.name)
    server = @conn.server(server.id)

    begin
      timeout(SERVER_BUILD_TIMEOUT) do
        until server.status == check_status do
          server = @conn.server(server.id)
          sleep 1
        end
      end
    rescue Timeout::Error => te
      fail('Timeout creating server.')
    end

    ping_test(server.addresses[:private][0])
    ssh_test(server.addresses[:private][0])

    server

  end

  def test_create_server

    # test data file to file inject into the server
    #tmp_file=Tempfile.new "server_tests"
    #tmp_file.write("yo")
    #tmp_file.flush

    # NOTE: When using AMI style images we rely on keypairs for SSH access
    #personalities={SSH_PUBLIC_KEY => "/root/.ssh/authorized_keys", tmp_file.path => "/tmp/foo/bar"}
    # NOTE: injecting two or more files doesn't work for now
    personalities={SSH_PUBLIC_KEY => "/root/.ssh/authorized_keys"}
    metadata={ "key1" => "value1", "key2" => "value2" }
    server = create_server(:name => "test1", :imageId => @image_id, :flavorId => 2, :personality => personalities, :metadata => metadata)
    assert_not_nil(server.adminPass)

    #boot an instance and check it
    check_server(server, @image_id, 2)

    image_id = @image_id
    if TEST_SNAPSHOT_IMAGE == "true" then

      #snapshot the image
      image = create_image(server, "My Backup")
      assert_equal('SAVING', image.status)
      assert_equal('My Backup', image.name)
      assert_equal(25, image.progress)
      assert_equal(server.id, image.serverId)
      assert_not_nil(image.created)
      assert_not_nil(image.id)

      begin
        timeout(SERVER_BUILD_TIMEOUT) do
          until image.status == 'ACTIVE' do
            image = @conn.image(image.id)
            sleep 1
          end
        end
      rescue Timeout::Error => te
        fail('Timeout creating image snapshot.')
      end

      image_id = image.id.to_s

    end

    if TEST_REBUILD_INSTANCE == "true" then
      # make sure our snapshot boots
      server.rebuild!(image_id)
      server = @conn.server(server.id)
      sleep 15 # sleep a couple seconds until rebuild starts
      check_server(server, image_id, 2)
    end

    if TEST_RESIZE_INSTANCE == "true" then
      # make sure our snapshot boots
      server.resize!(3)
      server = @conn.server(server.id)
      assert_equal('RESIZE', server.status)

      begin
        timeout(SERVER_BUILD_TIMEOUT) do
          until server.status == 'VERIFY_RESIZE' do
            server = @conn.server(server.id)
            sleep 1
          end
        end
      rescue Timeout::Error => te
        fail('Timeout resizing server.')
      end
 
      check_server(server, image_id, 3, 'VERIFY_RESIZE')

      server.confirm_resize!
      server = @conn.server(server.id)
      assert_equal('ACTIVE', server.status)

      check_server(server, image_id, 3)

    end

  end

end
