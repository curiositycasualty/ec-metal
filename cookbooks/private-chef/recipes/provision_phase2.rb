# encoding: utf-8
#
# Author:: Irving Popovetsky (<irving@getchef.com>)
# Copyright:: Copyright (c) 2014 Opscode, Inc.
#
# All Rights Reserved
#

bootstrap_host_name =
  node['private-chef']['backends'].select { |node,attrs| attrs['bootstrap'] == true }.values.first['hostname']

bootstrap_node_name =
  node['private-chef']['backends'].select { |node,attrs| attrs['bootstrap'] == true }.keys.first

package 'rsync'

execute 'rsync-from-bootstrap' do
  command "rsync -avz -e ssh --exclude chef-server-running.json root@#{bootstrap_host_name}:/etc/opscode/ /etc/opscode"
  action :run
  not_if { node.name == bootstrap_node_name }
end

ruby_block 'p-c-c reconfigure' do
  block do
    begin
      tries ||= 2
      cmd = Mixlib::ShellOut.new('/opt/opscode/bin/private-chef-ctl reconfigure')
      cmd.run_command
      if cmd.error?
        cmd.error!
      else
        ::File.open("/var/log/p-c-c-reconfigure-#{Time.now.strftime("%Y%m%d_%H%M%S")}.log", 'w') { |lf| lf.write(cmd.stdout) }
        puts '--- BEGIN private-chef-ctl reconfigure output ---'
        puts cmd.stdout
        puts '--- END private-chef-ctl reconfigure output ---'
      end
    rescue Exception => e
      ::File.open("/var/log/p-c-c-reconfigure-#{Time.now.strftime("%Y%m%d_%H%M%S")}.log", 'w') { |lf| lf.write(cmd.stdout) }
      puts "#{e} Previous private-chef-ctl reconfigure failed, sleeping for 30 and trying again"
      sleep 30
      unless (tries -= 1).zero?
        retry
      else
        raise 'private-chef-ctl reconfigure failed and retries exceeded'
      end
    end
  end
end

# OC-11297
execute 'fix-migration-state' do
  command '/opt/opscode/embedded/bin/bundle exec bin/partybus init'
  cwd '/opt/opscode/embedded/service/partybus'
  action :run
  not_if 'ls /var/opt/opscode/upgrades/migration-level'
  not_if 'ls /tmp/private-chef-perform-upgrade'
end

# If anything is still down, wait for things to settle
log "Running upgrades for #{node.name}, bootstrap is #{bootstrap_node_name}" do
  only_if { File.exists?('/tmp/private-chef-perform-upgrade') }
end

# OC-11382
execute 'waitforit' do
  command 'sleep 60'
  action :run
  only_if { node.name == bootstrap_node_name }
  only_if '/opt/opscode/bin/private-chef-ctl status | grep ^down'
  only_if 'ls /tmp/private-chef-perform-upgrade'
end

# after 1.2->1.4 upgrade postgresql won't be running, but WHY?
execute 'p-c-c-start' do
  command '/opt/opscode/bin/private-chef-ctl start'
  action :run
  only_if { node.name == bootstrap_node_name }
  only_if '/opt/opscode/bin/private-chef-ctl status | grep postgres | grep ^down'
  only_if 'ls /tmp/private-chef-perform-upgrade'
end

execute 'p-c-c-upgrade' do
  command '/opt/opscode/bin/private-chef-ctl upgrade'
  action :run
  only_if 'ls /tmp/private-chef-perform-upgrade'
end

execute 'p-c-c-cleanup' do
  command '/opt/opscode/bin/private-chef-ctl cleanup'
  action :run
  only_if 'rpm -q private-chef |grep private-chef-11'
  only_if 'ls /tmp/private-chef-perform-upgrade'
end

file '/tmp/private-chef-perform-upgrade' do
  action :delete
end
