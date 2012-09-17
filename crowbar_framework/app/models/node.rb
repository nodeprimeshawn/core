# Copyright 2012, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class Node < ActiveRecord::Base
  before_save :default_population
  
  attr_accessible :name, :description, :order, :state, :fingerprint, :admin, :allocated
  
  # 
  # Validate the name should unique (no matter the case)
  # and that it starts with a valid FQDN
  #
  validates_uniqueness_of :name, :case_sensitive => false, :message => I18n.t("db.notunique", :default=>"Name item must be unique")
  validates_format_of :name, :with=>/^(([a-zA-Z]|[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9]))*\.([A-Za-z]|[A-Za-z][A-Za-z0-9\-]*[A-Za-z0-9])*\.([A-Za-z]|[A-Za-z][A-Za-z0-9\-]*[A-Za-z0-9])$/, :message => I18n.t("db.fqdn", :default=>"Name must be a fully qualified domain name.")
  validates_length_of :name, :maximum => 255
  has_and_belongs_to_many :groups, :join_table => "node_groups", :foreign_key => "node_id", :order=>"[order], [name] ASC"
  
  belongs_to :os, :class_name => "Os" #, :foreign_key => "os_id"
  
  #
  # Helper function to test admin without calling admin. Style-thing.
  #
  def is_admin?
    node_object.admin? rescue false
  end

  #
  # Helper function for allocated
  #
  def allocated?
    allocated
  end

  def allocate
    allocated = true
    save
  end

  #
  # Find the CMDB object for now.  This should go away as the CMDB_Attribute pieces
  # materialize.
  #
  def node_object
    NodeObject.find_node_by_name name 
  end

  #
  # XXX: Remove this as we better.  THIS SHOULD BE READ_ONLY
  #
  def crowbar
    node_object.crowbar
  end

  #
  # This is an hack for now.
  # XXX: Once networking is better defined, we should use those routines
  #
  def address(net = "admin")
    node_object.address(net)
  end

  #
  # XXX: Remove this as we better.
  #
  def provisioner_state
    crowbar["provisioner_state"]
  end

  #
  # XXX: Remove this as we better.
  #
  def provisioner_state=(val)
    cno = node_object
    cno.crowbar["provisioner_state"] = val
    cno.save
  end

  def get_os
    node_object.crowbar["crowbar"]["os"] rescue nil
  end

  def set_os(target_os)
    cno = node_object
    cno.crowbar["crowbar"] ||= Mash.new
    cno.crowbar["crowbar"]["os"] = target_os
    cno.save
  end

  #
  # Override save so we can temporaily save the node_object.
  #
  def fix_node_object
    cno = node_object
    cno.crowbar["state"] = state
    cno.crowbar["allocated"] = allocated
    cno.save
  end

  #
  # XXX: Remove this as we better.
  #
  alias :super_save :save
  def save
    fix_node_object
    super_save
  end

  #
  # XXX: Remove this as we better.
  #
  alias :super_save! :save!
  def save!
    fix_node_object
    super_save!
  end
  
  #
  # Helper function to set state.  Assumes that the node will be save outside if this routine.
  #
  # Use transition function to set state.
  #
  def set_state(new_state)
    # use the real transition function for this
    cb = CrowbarService.new Rails.logger
    cb.transition "default", name, new_state
  end

  def ipmi_cmd(cmd)
    bmc          = node_object.address("bmc").addr rescue nil
    bmc_user     = node_object.get_bmc_user
    bmc_password = node_object.get_bmc_password
    system("ipmitool -I lanplus -H #{bmc} -U #{bmc_user} -P #{bmc_password} #{cmd}") unless bmc.nil?
  end

  def reboot
    set_state("reboot")
    ipmi_cmd("power cycle")
  end

  def shutdown
    set_state("shutdown")
    ipmi_cmd("power off")
  end

  def poweron
    set_state("poweron")
    ipmi_cmd("power on")
  end

  def identify
    ipmi_cmd("chassis identify")
  end


  # XXX: Make this better one day.  Perf is not good.  Direct select would be better
  # A custom query should be able to build the list straight up.
  #
  # update_run_list:
  #   Rebuilds the run_list for the CMDB system for this node based upon its active proposal
  #   membership and its state.
  #
  #   This includes updating the CMDB node role with node specific data.
  #
  def update_run_list
    nrs = NodeRole.find_all_by_node_id(self.id)
    # Get the active ones
    nrs = nrs.select { |x| x.proposal_config_id == x.proposal_config.proposal.active_config_id }

    # For each of the roles
    cno = node_object
    cno.clear_run_list_map
    nrs.each do |nr|
      if nr.role
        # This is node role that defines run_list entry
        cno.add_to_run_list(nr.role.name, nr.role.barclamp.cmdb_order, nr.role.states.split(","))
        config_name = "#{nr.role.barclamp.name}-config-#{nr.proposal_config.proposal.name}"
        cno.add_to_run_list(config_name, nr.role.barclamp.cmdb_order, ["all"])
      end
      # Has custom data.
      if nr.config
        hash = nr.config_hash
        cno.crowbar.merge(hash)
      end
    end
    cno.save
  end

  # Rob's list of CMDB attributes needed by the UI
    #alias
    #name
    #ip (list)
    #public_ip
    #mac
    #ipmi_enabled?
    #physical_drives (list)
    #memory (total)
    #cpu (type & count)
    #hardware (dmi product name)
    #raid_set
    #nics (list)
    #uptime
    #asset_tag
    #number_of_drives
    #physical_drives (list)
    #switch name, mac, port, unit
    #bios_set -> ["crowbar"]["hardware"]["bios_set"] 
    #get_bmc_user -> ["ipmi"]["bmc_user"] 
    #get_bmc_password-> ["ipmi"]["bmc_password"] 
    #bmc_address
  
  
  # Friendly name for the UI
  def alias
    (cmdb_get("alias") || name).split(".")[0]
  end

  def ready?
    state.eql? 'ready'
  end
  
  def virtual?
  end
  
  def bmc_set?
    # TODO place holder
    true
  end
  
  def links
    # TODO place holder for barclamp defined links
    []
  end

  # Makes the open ended state information into a subset of items for the UI
  def status
    # if you add new states then you MUST expand the PIE chart on the nodes index page
    subState = !state.nil? ? state.split[0].downcase : ""
    case subState
    when "ready"
      "ready"     #green
    when "discovered", "wait", "waiting", "user", "hold", "pending", "input"
      "pending"   #flashing yellow
    when "discovering", "reset", "delete", "reinstall", "shutdown", "reboot", "poweron", "noupdate"
      "unknown"   #grey
    when "problem", "issue", "error", "failed", "fail", "warn", "warning", "fubar", "alert", "recovering"
      "failed"    #flashing red
    when "hardware-installing", "hardware-install", "hardware-installed", "hardware-updated", "hardware-updating"
      "building"  #yellow
    else
      "unready"   #spinner
    end
  end  

  def cmdb_get(attribute)
    puts "CMDB looking up #{attribute}"
    begin 
      case attribute 
      when "alias"
        name.split(".")[0]
      when "switch_name"
        node_object.switch_name 
      when "switch_unit"
        node_object.switch_unit 
      when "switch_port"
        node_object.switch_port
      when "asset_tag"
        node_object.asset_tag
      else 
        "!! CMDB GET MISSING FOR #{attribute} !!"
      end
    rescue
      "!! CMDB ERROR for #{attribute} !!"
    end
  end
  
  def method_missing(m,*args,&block)
    method = m.to_s
    if method.starts_with? "cmdb_"
      return cmdb_get method[5..100]
    else
      puts "Node #{name} #{method.inspect} #{args.inspect} #{block.inspect}"
      Rails.logger.fatal("Cannot delegate method #{m} to #{self.class}")
      throw "ERROR #{method} not defined for node #{name}"
    end
  end
  
  def <=>(other)
    # use Array#<=> to compare the attributes
    [self.order, self.name] <=> [other.order, other.name]
  end

  def to_s
    "Node: #{name}"
  end
  
  private
  
  # make sure some safe values are set for the node
  def default_population
    self.fingerprint = self.name.hash
    self.name = self.name.downcase
    self.state ||= 'unknown' 
    if self.groups.size == 0
      g = Group.find_or_create_by_name :name=>'not_set', :description=>I18n.t('not_set', :default=>'Not Set')
      self.groups << g rescue nil 
    end
  end  
  
end
