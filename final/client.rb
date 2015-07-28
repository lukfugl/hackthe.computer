#!/usr/bin/env ruby

require 'rubygems'
require 'net/http'
require 'json'
require 'pqueue'

class Client
  NORTH = "north"
  SOUTH = "south"
  EAST = "east"
  WEST = "west"
  ORIENTATIONS = [NORTH, SOUTH, EAST, WEST]

  MOVE = "move"
  LEFT = "left"
  RIGHT = "right"
  FIRE = "fire"
  NOOP = "noop"
  ACTIONS = [MOVE, LEFT, RIGHT, FIRE, NOOP]

  def initialize(host, port, name, game)
    @host = host
    @port = port
    @name = name
    @game = game
    @finished = false
    join
  end

  # for taking a turn
  def move
    if clear_shot? && @energy > 0
      take_action(FIRE)
    elsif battery = find_closest_battery
      move_toward(battery)
    else
      move_toward(find_enemy)
    end
  end

  def at(location)
    x, y = location
    @grid[y][x]
  end

  def clear_shot?
    bullet = simulate_move(find_self, @orientation)
    loop do
      target = at(bullet)
      return true if target == 'O'
      return false if ['X', 'L'].include?(target)
      new_bullet = simulate_move(bullet, @orientation)
      return false if new_bullet == bullet
      bullet = new_bullet
    end
  end

  def find_enemy
    find_thing('O')
  end

  def find_closest_battery
    find_closest_thing('B')
  end

  def find_self
    find_thing('X')
  end

  def find_thing(thing)
    @grid.each_with_index do |line, j|
      line.each_with_index do |cell, i|
        return [i, j] if cell == thing
      end
    end
    return nil
  end

  def offset(a, b)
    tx, ty = a
    sx, sy = b
    dx = (tx - sx) % @width
    dx -= @width if dx > @width / 2
    dy = (ty - sy) % @height
    dy -= @height if dy > @height / 2
    return dx, dy
  end

  def offset_to(location)
    offset(find_self, location)
  end

  def range(a, b)
    dx, dy = offset(a, b)
    dx.abs + dy.abs
  end

  def range_to(location)
    range(find_self, location)
  end

  def find_closest_thing(thing)
    best = nil
    @grid.each_with_index do |line, j|
      line.each_with_index do |cell, i|
        next unless cell == thing
        location = [i, j]
        range = range_to(location)
        best = [location, range] if best.nil? || range < best.last
      end
    end
    return best && best.first
  end

  def simulate_move(position, orientation)
    x, y = position
    case orientation
    when NORTH
      y = (y - 1) % @height
    when SOUTH
      y = (y + 1) % @height
    when EAST
      x = (x + 1) % @width
    when WEST
      x = (x - 1) % @width
    end
    if @grid[y][x] == 'W'
      return position
    else
      return [x, y]
    end
  end

  def simulate_left(position, orientation)
    case orientation
    when NORTH then WEST
    when SOUTH then EAST
    when EAST then NORTH
    when WEST then SOUTH
    end
  end

  def simulate_right(position, orientation)
    case orientation
    when NORTH then EAST
    when SOUTH then WEST
    when EAST then SOUTH
    when WEST then NORTH
    end
  end

  def move_toward(location)
    score = -> (state) { state[2].size + range(state[0], location) }
    queue = PQueue.new([[find_self, @orientation, []]]) { |a,b| score.(a) < score.(b) }
    seen = {}
    until queue.empty?
      position, orientation, history, _ = queue.pop
      seen[[position, orientation]] = true
      if position == location
        take_action(history.first)
        return
      end
      ACTIONS.each do |action|
        case action
        when MOVE
          new_position = simulate_move(position, orientation)
          next if seen[[new_position, orientation]]
          queue << [new_position, orientation, history + [MOVE]]
        when LEFT
          new_orientation = simulate_left(position, orientation)
          next if seen[[position, new_orientation]]
          queue << [position, new_orientation, history + [LEFT]]
        when RIGHT
          new_orientation = simulate_right(position, orientation)
          next if seen[[position, new_orientation]]
          queue << [position, new_orientation, history + [RIGHT]]
        when FIRE, NOOP
          next
        end
      end
    end
    take_action(NOOP)
  end

  def take_action(action)
    receive_state(make_request(action))
  end

  # for starting a game
  def join
    data = make_request("join", 'X-Sm-Playermoniker' => @name)
    configure(data.delete('config'))
    receive_state(data)
    move until @finished
  end

  # for game start
  def configure(config)
    # how long you have each turn to take your turn, in nanoseconds. If you
    # take longer than this time, then you default to a noop action.
    @turn_timeout = config['turn_timeout']

    # a timeout value in seconds in which you have to respond before we assume
    # you are no longer player and you self destruct.
    @connect_back_timeout = config['connect_back_timeout']

    # how much health you start with
    @max_health = config['max_health']

    # how much energy you start with
    @max_energy = config['max_energy']

    # how much health you automatically lose each turn
    @health_loss = config['health_loss']

    # how much health is subtracted when hit by a laser
    @laser_damage = config['laser_damage']

    # how many cells a laser travels before fizzing out
    @laser_distance = config['laser_distance']

    # how much energy it takes to fire a laser
    @laser_energy = config['laser_energy']

    # how much energy is restored by picking up a battery, up to the
    # maximum_energy limit
    @battery_power = config['battery_power']

    # how much health is restored by picking up a battery, up to the
    # maximum_health limit
    @battery_health = config['battery_health']
  end

  # for starting a turn
  def receive_state(data)
    unless data['status'] == "running"
      @finished = true
      return
    end
    update_health(data['health'])
    update_energy(data['energy'])
    update_orientation(data['orientation'])
    update_grid(data['grid'])
  end

  def update_health(health)
    @health = health
  end

  def update_energy(energy)
    @energy = energy
  end

  def update_orientation(orientation)
    @orientation = orientation
  end

  def update_grid(grid)
    @grid = grid.each_line.map{ |line| line.chomp.each_char.to_a }
    @height = @grid.size
    @width = @grid.first.size
    track_bullets
  end

  def track_bullets
    @tracked_bullets ||= []
    seen = {}

    # update for those with known orientation
    delete = []
    @tracked_bullets.size.times do |i|
      position, orientation = @tracked_bullets[i]
      next unless orientation
      position = simulate_move(position, orientation)
      position = simulate_move(position, orientation)
      if at(position) == 'L' && !seen[position]
        seen[position] = true
        @tracked_bullets[i][0] = position
      else
        delete.unshift(i)
      end
    end
    delete.each{ |i| @tracked_bullets.delete_at(i) }

    # try and infer orientation for the remainder
    delete = []
    @tracked_bullets.size.times do |i|
      position, orientation = @tracked_bullets[i]
      next if orientation
      ORIENTATIONS.each do |new_orientation|
        new_position = simulate_move(position, new_orientation)
        new_position = simulate_move(new_position, new_orientation)
        if at(new_position) == 'L' && !seen[new_position]
          seen[new_position] = true
          @tracked_bullets[i][1] = new_orientation
          break
        end
      end
      delete.unshift(i) unless @tracked_bullets[i][1]
    end
    delete.each{ |i| @tracked_bullets.delete_at(i) }

    # discover any new bullets
    @grid.each_with_index do |line, j|
      line.each_with_index do |cell, i|
        location = [i, j]
        next if at(location) != 'L' || seen[location]
        @tracked_bullets << [location, nil]
      end
    end
  end

  # convenience
  def dump_grid
    puts @grid.map{ |line| line.join('') }.join("\n")
  end

  # HTTP communication
  def make_request(url, headers={})
    uri = "/game/#@game/#{url}"
    request = Net::HTTP::Post.new(uri)
    headers.each{ |key,val| request[key] = val }
    request['X-Sm-Playerid'] = @id if @id
    response = Net::HTTP.start(@host, @port) { |http| http.request(request) }
    if response.kind_of?(Net::HTTPSuccess)
      unless response.read_body && !response.read_body.empty?
        raise "Unexpected response: #{response.inspect}"
      end
    else
      raise "Unexpected response: #{response.inspect}"
      if response.read_body && !response.read_body.empty?
        puts response.read_body
      end
    end
    @id = response['X-Sm-Playerid'] if response['X-Sm-Playerid']
    JSON.parse(response.read_body)
  end
end

# read command line args
host = '192.168.1.4'
port = 8080
name = 'luk'
game = nil
ARGV.each do |arg|
  case arg
  when /^--host=(\S+)$/
    host = $1
  when /^--port=(\S+)$/
    port = $1.to_i
  when /^--name=(\S+)$/
    name = $1
  when /^--game=(\S+)$/
    game = $1
  end
end
raise ArgumentError, '--game=<id> is required' unless game

# create client
Client.new(host, port, name, game)
