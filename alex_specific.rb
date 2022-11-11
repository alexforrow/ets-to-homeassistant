# frozen_string_literal: true

def generate_obj(name, roles, ha_type = 'switch')
  {
    name: name.tr(',', '').capitalize,
    type: :custom, # unknown, so assume just switch
    ga: roles.keys,
    floor: 'unknown floor',
    room: 'unknown room',
    custom: { ha_type: ha_type }, # custom values
    roles: roles
  }
end

lambda do |knxconf|
  knx = knxconf.data

  # delete GAs not required in Home Assistant
  knx[:ga].delete_if{|_id, ga| ga[:address].start_with?('4/')} # Music TODO
  knx[:ga].delete_if{|_id, ga| ga[:address].start_with?('11/')} # Heartbeats TODO
  knx[:ga].delete_if{|_id, ga| ga[:address].start_with?('17/')} # Testing GA. Ignore
  

  # perform various manipulation on objs
  knx[:ob].each do |_k, o|
    # set name as room + function and strip capital betters except start
    o[:custom][:ha_init] = { 'name' => "#{o[:room]} #{o[:name]}".capitalize.gsub('air conditioning', 'HVAC') }
    #o[:custom][:ha_type] = 'switch' if o[:type].eql?(:custom)

    if o[:name].end_with?('isolator')
      o[:custom][:ha_type] = 'switch'
    end

    # Detect manually created GAs within functions - assign based on name
    o[:roles].select{|role, _ga_id| role =~ /^[a-z0-9\-]{36}$/}.each do |role, ga_id|
      ga = knx[:ga][ga_id]
      #pp ga_id
      #pp ga[:name].split(',').last.strip
      ga[:custom][:ha_address_type] =
        case ga[:name].split(',').last.strip
        when 'Running SW'
          'on_off_address'
        when 'Running FB'
          'on_off_state_address'
        when 'Setpoint feedback SETPFB'
          'target_temperature_state_address'
        when 'Operating mode feedback'
          'controller_mode_state_address'
        when 'Setpoint mode feedback'
          'operation_mode_state_address'
        when 'Setpoint mode' # comfort, eco, frost etc
          'operation_mode_address'
        else
          raise "Unable to match GA name #{ga[:name]} in function"
        end
    end

    if o[:name] =~ /Air conditioning/i
      o[:custom][:ha_init]['controller_modes'] = %w(Off Heat Cool Dry Fan\ only)
    end
  end

  # match up pairs of state and state_address switches
  objid = 0
  knx[:ga].select{|_id, g| g[:objs].empty?}
          .group_by{|_id, g| (g[:name].gsub(/ [A-Z]{2,5}$/,''))}
          .each do |name, matches|
    next unless matches.count > 1

    unless matches.to_h.values.map{|ga| ga[:datapoint]}.sort == [ "1.001", "1.011"]
      warn("Failed to pair up #{name}. Matching only works with standard switch and feedback")
      next
    end

    knx[:ob][objid] = generate_obj(
      name,
      {
        'SwitchOnOff' => matches.to_h.select{|_id, ga| ga[:datapoint] == '1.001'}.keys.first,
        'InfoOnOff' => matches.to_h.select{|_id, ga| ga[:datapoint] == '1.011'}.keys.first
      })
    
    matches.each{|_id, ga| ga[:objs].push(objid)} # mark GA with new object
    # prepare next object identifier
    objid += 1
  end

  # create objects for various known misc GAs
  knx[:ga].each do |id, ga|
    next if ga[:objs].count > 0 # only process GAs that aren't already in a funciton

    obj = nil
    case ga[:name]
    when /(error|fault)/i # various fault/error GAs
      ga[:custom][:ha_address_type] = 'state_address'
      obj = generate_obj(
        ga[:name].gsub(',', ' air conditioning').tr(':', ''),
        {
          'SwitchOnOff' => id,
        },
        ga[:name] =~ /error code/i ? 'sensor' : 'binary_sensor'
        )

      ga[:objs].push(objid) # mark GA with new object
      
    when /scene/i
      obj = generate_obj(
        ga[:name],
        {
          'SwitchOnOff' => id,
        },
        'number'
        )
        obj[:custom][:ha_init] = {
          'type' => 'scene_number'
        }
    when /motion/i
      obj = generate_obj(
        ga[:name],
        {
          'InfoOnOff' => id,
        },
        'binary_sensor'
        )
    when  /luminosity/i
      obj = generate_obj(
        ga[:name],
        {
          'InfoOnOff' => id,
        },
        'sensor'
        )
    when /disable switches/i
      obj = generate_obj(
        ga[:name],
        {
          'SwitchOnOff' => id,
        }
        )
    end

    if obj # did we do anything?
      knx[:ob][objid] = obj
      ga[:objs].push(objid) # mark GA with new object
      objid += 1
    end
  end
end
