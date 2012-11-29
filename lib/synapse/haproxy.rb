module Synapse
  class Haproxy < Base
    attr_reader :opts
    def initialize(opts)
      super()

      %w{global defaults reload_command config_file_path}.each do |req|
        raise ArgumentError, "haproxy requires a #{req} section" if !opts.has_key?(req)
      end

      @opts = opts
    end

    def update_config(watchers)
      new_config = generate_config(watchers)

      updated = write_config(new_config) if @opts['do_writes']
      restart if (updated && @opts['do_reloads'])
    end

    # generates a new config based on the state of the watchers
    def generate_config(watchers)
      new_config = generate_base_config + "\n"
      new_config << watchers.map {|w| generate_listen_stanza(w)}.join("\n")

      log "haproxy_config is: \n#{new_config}"
      return new_config
    end

    # generates the global and defaults sections of the config file
    def generate_base_config
      base_config = "# auto-generated by synapse at #{Time.now}\n"
      base_config << "# this config needs haproxy-1.1.28 or haproxy-1.2.1\n"

      %w{global defaults}.each do |section|
        base_config << "\n#{section}\n"
        @opts[section].each do |option|
          base_config << "\t#{option}\n"
        end
      end

      return base_config
    end

    # generates an individual stanza for a particular watcher
    def generate_listen_stanza(watcher)
      if watcher.backends.empty?
        log "no backends found for watcher #{watcher.name}" 
        return ""
      end

      stanza = "listen #{watcher.name} localhost:#{watcher.local_port}\n"

      watcher.listen.each do |line|
        stanza << "\t#{line}\n"
      end

      watcher.backends.each do |backend|
        stanza << "\tserver #{backend['name']} #{backend['host']}:#{backend['port']} #{watcher.server_options}\n" 
      end

      return stanza
    end

    # writes the config
    def write_config(new_config)
      old_config = File.read(@opts['config_file_path'])
      if old_config == new_config
        return false
      else
        File.open(@opts['config_file_path'],'w') {|f| f.write(new_config)}
        return true
      end
    end

    # restarts haproxy
    def restart
      safe_run(opts['reload_command'])
    end
  end
end