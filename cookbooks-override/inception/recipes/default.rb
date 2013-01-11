#
# Cookbook Name:: inception
# Recipe:: default
#
# Copyright 2012, Myplanet Digital, Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#

# Add so that we can set user passwords from databag
%w{
  make
  gcc
}.each do |pkg|
  package pkg do
    action :nothing
  end.run_action(:install)
end

chef_gem "ruby-shadow"

group "shadow" do
  members "jenkins"
  append true
  action :modify
end

log "restarting jenkins" do
  notifies :stop, "service[jenkins]", :immediately
  notifies :create, "ruby_block[netstat]", :immediately
  notifies :start, "service[jenkins]", :immediately
  notifies :create, "ruby_block[block_until_operational]", :immediately
  action :nothing
end

# Drop in global jenkins templates.
global_templates = [
  "hudson.plugins.ircbot.IrcPublisher.xml",
]

global_templates.each do |file|
  template "#{node['jenkins']['server']['home']}/#{file}" do
    source "#{file}.erb"
    owner node['jenkins']['server']['user']
    group node['jenkins']['server']['group']
    mode "0644"
  end
end

# Set global Jenkins config
template "#{node['jenkins']['server']['home']}/config.xml" do
  source "jenkins-config.xml.erb"
  owner node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
  mode "0644"
  notifies :write, "log[restarting jenkins]", :immediately
end

directory node['jenkins']['node']['home'] do
  owner node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
end

# In order to run authorized tasks (like updating job config), we need to
# authorize as a Jenkins user. We have Jenkins set to authorize against the
# unix user database, so we can use the `users` databag to build a URL and
# therefore use HTTP basic auth.

# Get any user and use the common password
auth_username = data_bag("users").first
auth_pass = node['user']['password']

# If login throws an error, assume it's because jenkins doesn't need it.
jenkins_cli "login --username #{auth_username} --password '#{auth_pass}'"

repo = node['inception']['repo']
github_url = "http://github.com/#{repo.sub(/^.*[:\/](.*\/.*).git$/, '\\1')}"

build_jobs = node['inception']['build_jobs']

# Prepare each job
[*build_jobs, nil].each_cons(2) do |job_name, next_job|
  job_config = File.join(node['jenkins']['node']['home'], "#{job_name}-config.xml")

  jenkins_job job_name do
    action :nothing
    config job_config
  end

  template job_config do
    source "job-config.xml.erb"
    variables({
      :repo => repo,
      :github_url => github_url,
      :branch => node['inception']['branch'],
      :job_name => job_name,
      :next_job => next_job,
      # Is this the first job?
      :trigger_job => (job_name == build_jobs.first),
    })
    notifies :update, "jenkins_job[#{job_name}]", :immediately
  end
end

%w{
  deploy
}.each do |type|
  cookbook_file "/var/lib/jenkins/#{type}.logparserules.txt" do
    source "#{type}.logparserules.txt"
    owner node['jenkins']['server']['user']
    group node['jenkins']['server']['group']
    mode "0644"
  end
end
