require 'synapse/config_generator/base'

require 'fileutils'

class Synapse::ConfigGenerator
  class Nginx < BaseGenerator
    include Synapse::Logging

    NAME = 'nginx'.freeze

    def initialize(opts)
      %w{main events}.each do |req|
        if !opts.fetch('contexts', {}).has_key?(req)
          raise ArgumentError, "nginx requires a contexts.#{req} section"
        end
      end

      @opts = opts
      @contexts = opts['contexts']
      @opts['do_writes'] = true unless @opts.key?('do_writes')
      @opts['do_reloads'] = true unless @opts.key?('do_reloads')

      req_pairs = {
        'do_writes' => ['config_file_path', 'check_command'],
        'do_reloads' => ['reload_command', 'start_command'],
      }

      req_pairs.each do |cond, reqs|
        if opts[cond]
          unless reqs.all? {|req| opts[req]}
            missing = reqs.select {|req| not opts[req]}
            raise ArgumentError, "the `#{missing}` option(s) are required when `#{cond}` is true"
          end
        end
      end

      # how to restart nginx
      @restart_interval = @opts.fetch('restart_interval', 2).to_i
      @restart_jitter = @opts.fetch('restart_jitter', 0).to_f
      @restart_required = true
      @has_started = false

      # virtual clock bookkeeping for controlling how often nginx restarts
      @time = 0
      @next_restart = @time

      # a place to store the parsed nginx config from each watcher
      @watcher_configs = {}
    end

    def normalize_config_generator_opts!(service_watcher_name, service_watcher_opts)
      service_watcher_opts['mode'] ||= 'http'
      %w{upstream server}.each do |sec|
        service_watcher_opts[sec] ||= []
      end
      unless service_watcher_opts.include?('port')
        log.warn "synapse: service #{service_watcher_name}: nginx config does not include a port; only upstream sections for the service will be created; you must move traffic there manually using server sections"
      end
      service_watcher_opts['disabled'] |= false
    end


    def tick(watchers)
      @time += 1

      # We potentially have to restart if the restart was rate limited
      # in the original call to update_config
      restart if @opts['do_reloads'] && @restart_required
    end

    def update_config(watchers)
      # generate a new config
      new_config = generate_config(watchers)

      # if we write config files, lets do that and then possibly restart
      if @opts['do_writes']
        @restart_required = write_config(new_config)
        restart if @opts['do_reloads'] && @restart_required
      end
    end

    # generates a new config based on the state of the watchers
    def generate_config(watchers)
      new_config = generate_base_config

      http, stream = [], []
      watchers.each do |watcher|
        watcher_config = watcher.generator_config['nginx']
        next if watcher_config['disabled']

        section = case watcher_config['mode']
          when 'http'
            http
          when 'tcp'
            stream
          else
            raise ArgumentError, "synapse does not understand #{watcher_config['mode']} as a service mode"
        end
        section << generate_server(watcher).flatten
        section << generate_upstream(watcher).flatten
      end

      unless http.empty?
        new_config << 'http {'
        new_config.concat(http.flatten)
        new_config << "}\n"
      end

      unless stream.empty?
        new_config << 'stream {'
        new_config.concat(stream.flatten)
        new_config << "}\n"
      end

      log.debug "synapse: new nginx config: #{new_config}"
      return new_config.flatten.join("\n")
    end

    # generates the global and defaults sections of the config file
    def generate_base_config
      base_config = ["# auto-generated by synapse at #{Time.now}\n"]

      # The "main" context is special and is the top level
      @contexts['main'].each do |option|
        base_config << "#{option};"
      end
      base_config << "\n"

      # http and streams are generated separately
      @contexts.keys.select{|key| !(["main", "http", "stream"].include?(key))}.each do |context|
        base_config << "#{context} {"
        @contexts[context].each do |option|
          base_config << "\t#{option};"
        end
        base_config << "}\n"
      end
      return base_config
    end

    def generate_server(watcher)
      watcher_config = watcher.generator_config['nginx']
      unless watcher_config.has_key?('port')
        log.debug "synapse: not generating server stanza for watcher #{watcher.name} because it has no port defined"
        return []
      else
        port = watcher_config['port']
      end

      listen_address = (
        watcher_config['listen_address'] ||
        @opts['listen_address'] ||
        'localhost'
      )
      upstream_name = watcher_config.fetch('upstream_name', watcher.name)

      stanza = [
        "\tserver {",
        "\t\tlisten #{listen_address}:#{port};",
        watcher_config['server'].map {|c| "\t\t#{c};"},
        generate_proxy(watcher_config['mode'], upstream_name),
        "\t}",
      ]
    end

    # Nginx has some annoying differences between how upstreams in the
    # http (http) module and the stream (tcp) module address upstreams
    def generate_proxy(mode, upstream_name)
      upstream_name = "http://#{upstream_name}" if mode == 'http'

      case mode
      when 'http'
        stanza = [
          "\t\tlocation / {",
          "\t\t\tproxy_pass #{upstream_name};",
          "\t\t}"
        ]
      when 'tcp'
        stanza = [
          "\t\tproxy_pass #{upstream_name};",
        ]
      else
        []
      end
    end

    def generate_upstream(watcher)
      backends = {}
      watcher_config = watcher.generator_config['nginx']
      upstream_name = watcher_config.fetch('upstream_name', watcher.name)

      watcher.backends.each {|b| backends[construct_name(b)] = b}

      # nginx doesn't like upstreams with no backends?
      return [] if backends.empty?

      keys = case watcher_config['upstream_order']
      when 'asc'
        backends.keys.sort
      when 'desc'
        backends.keys.sort.reverse
      when 'no_shuffle'
        backends.keys
      else
        backends.keys.shuffle
      end

      stanza = [
        "\tupstream #{upstream_name} {",
        watcher_config['upstream'].map {|c| "\t\t#{c};"},
        keys.map {|backend_name|
          backend = backends[backend_name]
          b = "\t\tserver #{backend['host']}:#{backend['port']}"
          b = "#{b} #{watcher_config['server_options']}" if watcher_config['server_options']
          "#{b};"
        },
        "\t}"
      ]
    end

    # writes the config
    def write_config(new_config)
      begin
        old_config = File.read(@opts['config_file_path'])
      rescue Errno::ENOENT => e
        log.info "synapse: could not open nginx config file at #{@opts['config_file_path']}"
        old_config = ""
      end

      if old_config == new_config
        return false
      else
        File.open(@opts['config_file_path'],'w') {|f| f.write(new_config)}
        check = `#{@opts['check_command']}`.chomp
        unless $?.success?
          log.error "synapse: nginx configuration is invalid according to #{@opts['check_command']}!"
          log.error 'synapse: not restarting nginx as a result'
          return false
        end

        return true
      end
    end

    # restarts nginx if the time is right
    def restart
      if @time < @next_restart
        log.info "synapse: at time #{@time} waiting until #{@next_restart} to restart"
        return
      end

      @next_restart = @time + @restart_interval
      @next_restart += rand(@restart_jitter * @restart_interval + 1)

      # do the actual restart
      unless @has_started
        log.info "synapse: attempting to run #{@opts['start_command']} to get nginx started"
        log.info 'synapse: this can fail if nginx is already running'
        res = `#{@opts['start_command']}`.chomp
        @has_started = true
      end

      res = `#{@opts['reload_command']}`.chomp
      unless $?.success?
        log.error "failed to reload nginx via #{@opts['reload_command']}: #{res}"
        return
      end
      log.info "synapse: restarted nginx"

      @restart_required = false
    end

    # used to build unique, consistent nginx names for backends
    def construct_name(backend)
      name = "#{backend['host']}:#{backend['port']}"
      if backend['name'] && !backend['name'].empty?
        name = "#{backend['name']}_#{name}"
      end

      return name
    end
  end
end
