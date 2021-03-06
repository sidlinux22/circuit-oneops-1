# Copyright 2016, Walmart Stores, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Cookbook Name:: fqdn
# Recipe:: set_dns_entries
#
# uses node[:entries] list of dns entries based on entrypoint, aliases, zone, and platform to update dns
# no ManagedVia - recipes will run on the gw

# get dns record type - check for ip addresses
def get_record_type (dns_name, dns_values)
  record_type = "cname"
  ips = dns_values.grep(/\d+\.\d+\.\d+\.\d+/)
  if ips.size > 0
    record_type = "a"
  end
  if dns_name =~ /^\d+\.\d+\.\d+\.\d+$/
    record_type = "ptr"
  end

  return record_type
end


def delete_dns (dns_name, dns_value)

  delete_type = get_record_type(dns_name,[dns_value])
  Chef::Log.info("delete #{delete_type}: #{dns_name} to #{dns_value}")
  
  cmd_content = node.ddns_header + "update delete #{dns_name} #{delete_type.upcase} #{dns_value}\nsend\n"
  cmd_file = node.ddns_key_file + '-cmd'
  File.open(cmd_file, 'w') { |file| file.write(cmd_content) }
  cmd = "nsupdate -k #{node.ddns_key_file} #{cmd_file}"
  puts cmd
  result = `#{cmd}`
  
end

def get_existing_dns (dns_name,ns)
  existing_dns = Array.new
  if dns_name =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/
    ptr_name = $4 +'.' + $3 + '.' + $2 + '.' + $1 + '.in-addr.arpa'
    cmd = "dig +short PTR #{ptr_name} @#{ns}"
    Chef::Log.info(cmd)
    existing_dns += `#{cmd}`.split("\n").map! { |v| v.gsub(/\.$/,"") }
  else
    ["A","CNAME"].each do |record_type|
      Chef::Log.info("dig +short #{record_type} #{dns_name} @#{ns}")
      vals = `dig +short #{record_type} #{dns_name} @#{ns}`.split("\n").map! { |v| v.gsub(/\.$/,"") }
      # skip dig's lenient A record lookup thru CNAME
      next if record_type == "A" && vals.size > 1 && vals[0] !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/
      existing_dns += vals
    end
  end
  Chef::Log.info("existing: "+existing_dns.sort.inspect)
  return existing_dns
end

include_recipe "fqdn::get_ddns_connection"

cloud_name = node[:workorder][:cloud][:ciName]
domain_name = node[:workorder][:services][:dns][cloud_name][:ciAttributes][:zone]
cmd_file = node.ddns_key_file + '-cmd'
ns = node.ns

deletable_values = []
if node.has_key?("deletable_entries")
  node.deletable_entries.each do |deletable_entry|
    if deletable_entry[:values].is_a?(String)
      deletable_values.push(deletable_entry[:values])
    else
      deletable_values += deletable_entry[:values]
    end
  end
end

deletable_values.uniq!

#
# delete / create dns entries
#
node[:entries].each do |entry|
  dns_match = false
  dns_name = entry[:name]
  dns_values = entry[:values].is_a?(String) ? Array.new([entry[:values]]) : entry[:values]

  dns_type = get_record_type(dns_name,dns_values)

  if dns_name.empty? || dns_name =~ /^\*$/
   Chef::Log.error("invalid dns_name: #{dns_name}")
   exit 1
  end

  # put a value for wildcard dns entries
  dns_name_for_lookup = dns_name.gsub("\*","abc123")
  Chef::Log.info("#{dns_name_for_lookup} new values: "+dns_values.sort.inspect)

  existing_dns = get_existing_dns(dns_name,ns)

  Chef::Log.info("previous entries: #{node.previous_entries}")
  Chef::Log.info("deletable_values: #{deletable_values}")
  
  
  if existing_dns.length > 0 || node[:dns_action] == "delete"
    
    # cleanup or delete
    existing_dns.each do |existing_entry|
      if deletable_values.include?(existing_entry) &&
         (dns_values.include?(existing_entry) && node[:dns_action] == "delete") ||          
         # value was in previous entry, but not anymore
         (!dns_values.include?(existing_entry) &&
          node.previous_entries.has_key?(dns_name) &&
          node.previous_entries[dns_name].include?(existing_entry) && 
          node[:dns_action] != "delete")

        delete_dns(dns_name, existing_entry)
      end
    end

  end

  # delete workorder skips the create call
  if node[:dns_action] == "delete"
    next
  end


  # infoblox has multiple record values for round-robin entries
  # View attribute extracted from infoblox metadata to make it configurable item
  dns_values.each do |dns_value|
    
    if existing_dns.include?(dns_value)
      Chef::Log.info("exists #{dns_type}: #{dns_name} to #{dns_values.to_s}")
      next        
    end
    
    Chef::Log.info("create #{dns_type}: #{dns_name} to #{dns_values.to_s}")
    
    ttl = 60
    if node.workorder.rfcCi.ciAttributes.has_key?("ttl")
      ttl = node.workorder.rfcCi.ciAttributes.ttl.to_i
    end
    
    type = get_record_type(dns_name,[dns_value])
    cmd_content = node.ddns_header + "update add #{dns_name} #{ttl} #{type.upcase} #{dns_value}\nsend\n"
    puts "cmd_content: #{cmd_content}"
    File.open(cmd_file, 'w') { |file| file.write(cmd_content) }
    cmd = "nsupdate -k #{node.ddns_key_file} #{cmd_file}"
    puts cmd
    result = `#{cmd}`    
    
    if result =~ /error/i
      puts "***FAULT:FATAL=#{result}"
      e = Exception.new("no backtrace")
      e.set_backtrace("")
      raise e
    end
    
    # verify using authoratative dns sever
    sleep 5
    verified = false
    max_retry_count = 30
    retry_count = 0

    while !verified && retry_count<max_retry_count do
      dns_lookup_name = dns_name
      if dns_name =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/
        dns_lookup_name = $4 +'.' + $3 + '.' + $2 + '.' + $1 + '.in-addr.arpa'
      end
      if ns
        existing_dns = `dig +short #{dns_type} #{dns_lookup_name} @#{ns}`.split("\n").map! { |v| v.gsub(/\.$/,"") }
      else
        existing_dns = `dig +short #{dns_type} #{dns_lookup_name}`.split("\n").map! { |v| v.gsub(/\.$/,"") }
      end

      Chef::Log.info("verify ns has: "+dns_value)
      Chef::Log.info("ns #{ns} has: "+existing_dns.sort.to_s)
      verified = false
      existing_dns.each do |val|
        val = dns_value
        if dns_value[-1,1] == '.'
          val = dns_value.chop
        end
        if val.downcase.include? val
          verified = true
          Chef::Log.info("verified.")
        end
      end
      if !verified
        Chef::Log.info("waiting 10sec for #{ns} to get updated...")
        sleep 10
      end
      retry_count +=1
    end

    if verified == false
      msg = "dns could not be verified after 5min!"
      Chef::Log.error(msg)
      puts "***FAULT:FATAL=#{msg}"
      e = Exception.new("no backtrace")
      e.set_backtrace("")
      raise e
    end
  end

end

File.delete(node.ddns_key_file)
if File.exists?(cmd_file)
  File.delete(cmd_file)  
end
