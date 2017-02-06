require 'spec_helper'
require 'synapse/config_generator/nginx'

class MockWatcher; end;

describe Synapse::ConfigGenerator::Nginx do
  subject { Synapse::ConfigGenerator::Nginx.new(config['nginx']) }

  let(:mockwatcher) do
    mockWatcher = double(Synapse::ServiceWatcher)
    allow(mockWatcher).to receive(:name).and_return('example_service')
    backends = [{ 'host' => 'somehost', 'port' => 5555}]
    allow(mockWatcher).to receive(:backends).and_return(backends)
    allow(mockWatcher).to receive(:generator_config).and_return({
      'nginx' => {'server_options' => "check inter 2000 rise 3 fall 2"}
    })
    mockWatcher
  end

  let(:mockwatcher_disabled) do
    mockWatcher = double(Synapse::ServiceWatcher)
    allow(mockWatcher).to receive(:name).and_return('disabled_watcher')
    backends = [{ 'host' => 'somehost', 'port' => 5555}]
    allow(mockWatcher).to receive(:backends).and_return(backends)
    allow(mockWatcher).to receive(:generator_config).and_return({
      'nginx' => {'port' => 2200, 'disabled' => true}
    })
    mockWatcher
  end

  describe 'validates arguments' do
    it 'succeeds on minimal config' do
      conf = {
        'contexts' => {'main' => [], 'events' => []},
      }
      Synapse::ConfigGenerator::Nginx.new(conf)
      expect{Synapse::ConfigGenerator::Nginx.new(conf)}.not_to raise_error
    end

    it 'validates req_pairs' do
      req_pairs = {
        'do_writes' => 'config_file_path',
        'do_writes' => 'check_command',
        'do_reloads' => 'reload_command',
        'do_reloads' => 'start_command',
      }
      valid_conf = {
        'do_reloads' => false,
        'do_socket' => false,
        'do_writes' => false
      }

      req_pairs.each do |key, value|
        conf = valid_conf.clone
        conf[key] = true
        expect{Synapse::ConfigGenerator::nginx.new(conf)}.
          to raise_error(ArgumentError, "the `#{value}` option is required when `#{key}` is true")
      end
    end

    it 'properly defaults do_writes, do_reloads' do
      conf = {
        'config_file_path' => 'test_file',
        'reload_command' => 'test_reload',
        'start_command' => 'test_start',
        'check_command' => 'test_check'
      }
      expect{Synapse::ConfigGenerator::Nginx.new(conf)}.not_to raise_error
      nginx = Synapse::ConfigGenerator::Haproxy.new(conf)
      expect(nginx.instance_variable_get(:@opts)['do_writes']).to eql(true)
      expect(nginx.instance_variable_get(:@opts)['do_reloads']).to eql(true)
    end

    it 'complains when main or events are not passed at all' do
      conf = {
        'contexts' => []
      }
      expect{Synapse::ConfigGenerator::Nginx.new(conf)}.to raise_error(ArgumentError)
    end
  end

  describe '#name' do
    it 'returns nginx' do
      expect(subject.name).to eq('nginx')
    end
  end

  describe 'disabled watcher' do
    let(:watchers) { [mockwatcher, mockwatcher_disabled] }
    let(:socket_file_path) { 'socket_file_path' }

    before do
      config['nginx']['do_socket'] = true
      config['nginx']['socket_file_path'] = socket_file_path
    end

    it 'does not generate config' do
      allow(subject).to receive(:parse_watcher_config).and_return({})
      expect(subject).to receive(:generate_frontend_stanza).exactly(:once).with(mockwatcher, nil)
      expect(subject).to receive(:generate_backend_stanza).exactly(:once).with(mockwatcher, nil)
      subject.update_config(watchers)
    end

    it 'does not cause a restart due to the socket' do
      mock_socket_output = "example_service,somehost:5555"
      subject.instance_variable_set(:@restart_required, false)
      allow(subject).to receive(:talk_to_socket).with(socket_file_path, "show stat\n").and_return mock_socket_output
      allow(subject).to receive(:generate_config).exactly(:once).and_return 'mock_config'
      expect(subject).to receive(:talk_to_socket).exactly(:once).with(
        socket_file_path, "enable server example_service/somehost:5555\n"
      ).and_return "\n"
      subject.update_config(watchers)

      expect(subject.instance_variable_get(:@restart_required)).to eq false
    end
  end
end
