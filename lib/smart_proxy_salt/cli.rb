# frozen_string_literal: true

require 'English'

module Proxy
  module Salt
    # CLI methods
    module CLI
      extend ::Proxy::Log
      extend ::Proxy::Util

      class << self
        def autosign_file
          Proxy::Salt::Plugin.settings.autosign_file
        end

        def autosign_create(host)
          FileUtils.touch(autosign_file) unless File.exist?(autosign_file)

          autosign = open(autosign_file, File::RDWR)

          found = false
          autosign.each_line { |line| found = true if line.chomp == host }
          autosign.puts host unless found
          autosign.close

          result = { :message => "Added #{host} to autosign" }
          logger.info result[:message]
          result
        end

        def autosign_remove(host)
          raise "No such file #{autosign_file}" unless File.exist?(autosign_file)

          found = false
          entries = open(autosign_file, File::RDONLY).readlines.collect do |l|
            if l.chomp != host
              l
            else
              found = true
              nil
            end
          end.uniq.compact
          if found
            autosign = open(autosign_file, File::TRUNC | File::RDWR)
            autosign.write entries.join("\n")
            autosign.write "\n"
            autosign.close
            result = { :message => "Removed #{host} from autosign" }
            logger.info result[:message]
            result
          else
            logger.info "Attempt to remove nonexistant client autosign for #{host}"
            raise Proxy::Salt::NotFound.new("Attempt to remove nonexistant client autosign for #{host}")
          end
        end

        def autosign_list
          return [] unless File.exist?(autosign_file)
          File.read(autosign_file).split("\n").reject do |v|
            v =~ /^\s*#.*|^$/ ## Remove comments and empty lines
          end.map(&:chomp)
        end

        def highstate(host)
          find_salt_binaries
          cmd = [@sudo, '-u', Proxy::Salt::Plugin.settings.salt_command_user, @salt, '--async', escape_for_shell(host), 'state.highstate']
          logger.info "Will run state.highstate for #{host}. Full command: #{cmd.join(' ')}"
          shell_command(cmd)
        end

        def refresh_pillar(host)
          find_salt_binaries
          cmd = [@sudo, '-u', Proxy::Salt::Plugin.settings.salt_command_user, @salt, '--async', escape_for_shell(host), 'saltutil.refresh_pillar']
          logger.info "Will run saltutil.refresh_pillar for #{host}. Full command: #{cmd.join(' ')}"
          shell_command(cmd)
        end

        def key_delete(host)
          find_salt_binaries
          cmd = [@sudo, '-u', Proxy::Salt::Plugin.settings.salt_command_user, @salt_key, '--yes', '-d', escape_for_shell(host)]
          shell_command(cmd)
        end

        def key_reject(host)
          find_salt_binaries
          cmd = [@sudo, '-u', Proxy::Salt::Plugin.settings.salt_command_user, @salt_key, '--include-accepted', '--yes', '-r', escape_for_shell(host)]
          shell_command(cmd)
        end

        def key_accept(host)
          find_salt_binaries
          cmd = [@sudo, '-u', Proxy::Salt::Plugin.settings.salt_command_user, @salt_key, '--include-rejected', '--yes', '-a', escape_for_shell(host)]
          shell_command(cmd)
        end

        def key_list
          find_salt_binaries
          command = "#{@sudo} -u #{Proxy::Salt::Plugin.settings.salt_command_user} #{@salt_key} --finger-all --output=json"
          logger.debug "Executing #{command}"
          response = `#{command}`
          unless $CHILD_STATUS == 0
            logger.warn "Failed to run salt-key: #{response}"
            raise 'Execution of salt-key failed, check log files'
          end

          keys_hash = {}

          sk_hash = JSON.parse(response)

          accepted_minions = sk_hash['minions']
          accepted_minions.each_key { |accepted_minion| keys_hash[accepted_minion] = { 'state' => 'accepted', 'fingerprint' => accepted_minions[accepted_minion] } } if sk_hash.key? 'minions'

          rejected_minions = sk_hash['minions_rejected']
          rejected_minions.each_key { |rejected_minion| keys_hash[rejected_minion] = { 'state' => 'rejected', 'fingerprint' => rejected_minions[rejected_minion] } } if sk_hash.key? 'minions_rejected'

          unaccepted_minions = sk_hash['minions_pre']
          unaccepted_minions.each_key { |unaccepted_minion| keys_hash[unaccepted_minion] = { 'state' => 'unaccepted', 'fingerprint' => unaccepted_minions[unaccepted_minion] } } if sk_hash.key? 'minions_pre'

          keys_hash
        end

        private

        def shell_command(cmd, wait = true)
          begin
            c = popen(cmd)
            unless wait
              Process.detach(c.pid)
              return 0
            end
            Process.wait(c.pid)
            logger.info("Result: #{c.read}")
          rescue Exception => e
            logger.error("Exception '#{e}' when executing '#{cmd}'")
            return false
          end
          logger.warn("Non-null exit code when executing '#{cmd}'") unless $CHILD_STATUS.success?
          $CHILD_STATUS.success?
        end

        def popen(cmd)
          # 1.8.7 note: this assumes that cli options are space-separated
          cmd = cmd.join(' ') unless RUBY_VERSION > '1.8.7'
          logger.debug("about to execute: #{cmd}")
          IO.popen(cmd)
        end

        def find_salt_binaries
          @salt_key = which('salt-key')
          unless File.exist?(@salt_key.to_s)
            logger.warn 'unable to find salt-key binary'
            raise 'unable to find salt-key'
          end
          logger.debug "Found salt-key at #{@salt_key}"

          @salt = which('salt')
          unless File.exist?(@salt.to_s)
            logger.warn 'unable to find salt binary'
            raise 'unable to find salt'
          end
          logger.debug "Found salt at #{@salt}"

          @sudo = which('sudo')
          unless File.exist?(@sudo)
            logger.warn 'unable to find sudo binary'
            raise 'Unable to find sudo'
          end
          logger.debug "Found sudo at #{@sudo}"
          @sudo = @sudo.to_s
        end
      end
    end
  end
end
