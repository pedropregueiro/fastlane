require 'open3'
require 'plist'

module FastlaneCore
  class DeviceManager
    class << self
      def all(requested_os_type = "")
        return connected_devices(requested_os_type) + simulators(requested_os_type)
      end

      def simulators(requested_os_type = "")
        UI.verbose("Fetching available simulator devices")

        @devices = []
        os_type = 'unknown'
        os_version = 'unknown'
        output = ''
        Open3.popen3('xcrun simctl list devices') do |stdin, stdout, stderr, wait_thr|
          output = stdout.read
        end

        unless output.include?("== Devices ==")
          UI.error("xcrun simctl CLI broken, run `xcrun simctl list devices` and make sure it works")
          UI.user_error!("xcrun simctl not working.")
        end

        output.split(/\n/).each do |line|
          next if line =~ /^== /
          if line =~ /^-- /
            (os_type, os_version) = line.gsub(/-- (.*) --/, '\1').split
          else
            # iPad 2 (0EDE6AFC-3767-425A-9658-AAA30A60F212) (Shutdown)
            # iPad Air 2 (4F3B8059-03FD-4D72-99C0-6E9BBEE2A9CE) (Shutdown) (unavailable, device type profile not found)
            if line.include?("inch)")
              # For Xcode 8, where sometimes we have the # of inches in ()
              # iPad Pro (12.9 inch) (CEF11EB3-79DF-43CB-896A-0F33916C8BDE) (Shutdown)
              match = line.match(/\s+([^\(]+ \(.*inch\)) \(([-0-9A-F]+)\) \(([^\(]+)\)(.*unavailable.*)?/)
            else
              match = line.match(/\s+([^\(]+) \(([-0-9A-F]+)\) \(([^\(]+)\)(.*unavailable.*)?/)
            end

            if match && !match[4] && (os_type == requested_os_type || requested_os_type == "")
              @devices << Device.new(name: match[1], os_type: os_type, os_version: os_version, udid: match[2], state: match[3], is_simulator: true)
            end
          end
        end

        return @devices
      end

      def connected_devices(requested_os_type)
        UI.verbose("Fetching available connected devices")

        device_types = if requested_os_type == "tvOS"
                         ["AppleTV"]
                       elsif requested_os_type == "iOS"
                         ["iPhone", "iPad", "iPod"]
                       else
                         []
                       end

        devices = [] # Return early if no supported devices are being searched for
        if device_types.count == 0
          return devices
        end

        usb_devices_output = ''
        Open3.popen3("system_profiler SPUSBDataType -xml") do |stdin, stdout, stderr, wait_thr|
          usb_devices_output = stdout.read
        end

        device_uuids = []
        result = Plist.parse_xml(usb_devices_output)

        discover_devices(result[0], device_types, device_uuids) if result[0]

        if device_uuids.count > 0 # instruments takes a little while to return so skip it if we have no devices
          instruments_devices_output = ''
          Open3.popen3("instruments -s devices") do |stdin, stdout, stderr, wait_thr|
            instruments_devices_output = stdout.read
          end

          instruments_devices_output.split(/\n/).each do |instruments_device|
            device_uuids.each do |device_uuid|
              match = instruments_device.match(/(.+) \(([0-9.]+)\) \[([0-9a-f]+)\]?/)
              if match && match[3] == device_uuid
                devices << Device.new(name: match[1], udid: match[3], os_type: requested_os_type, os_version: match[2], state: "Booted", is_simulator: false)
                UI.verbose("USB Device Found - \"" + match[1] + "\" (" + match[2] + ") UUID:" + match[3])
              end
            end
          end
        end

        return devices
      end

      # Recursively handle all USB items, discovering devices that match the
      # desired types.
      def discover_devices(usb_item, device_types, discovered_device_udids)
        (usb_item['_items'] || []).each do |child_item|
          discover_devices(child_item, device_types, discovered_device_udids)
        end

        is_supported_device = device_types.any? { |device_type| usb_item['_name'] == device_type }
        has_serial_number = (usb_item['serial_num'] || '').length == 40

        if is_supported_device && has_serial_number
          discovered_device_udids << usb_item['serial_num']
        end
      end

      # The code below works from Xcode 7 on
      # def all
      #   UI.verbose("Fetching available devices")

      #   @devices = []
      #   output = ''
      #   Open3.popen3('xcrun simctl list devices --json') do |stdin, stdout, stderr, wait_thr|
      #     output = stdout.read
      #   end

      #   begin
      #     data = JSON.parse(output)
      #   rescue => ex
      #     UI.error(ex)
      #     UI.error("xcrun simctl CLI broken, run `xcrun simctl list devices` and make sure it works")
      #     UI.user_error!("xcrun simctl not working.")
      #   end

      #   data["devices"].each do |os_version, l|
      #     l.each do |device|
      #       next if device['availability'].include?("unavailable")
      #       next unless os_version.include?(requested_os_type)

      #       os = os_version.gsub(requested_os_type + " ", "").strip
      #       @devices << Device.new(name: device['name'], os_type: requested_os_type, os_version: os, udid: device['udid'])
      #     end
      #   end

      #   return @devices
      # end
    end

    # Use the UDID for the given device when setting the destination
    # Why? Because we might get this error message
    # > The requested device could not be found because multiple devices matched the request.
    #
    # This happens when you have multiple simulators for a given device type / iOS combination
    #   { platform:iOS Simulator, id:1685B071-AFB2-4DC1-BE29-8370BA4A6EBD, OS:9.0, name:iPhone 5 }
    #   { platform:iOS Simulator, id:A141F23B-96B3-491A-8949-813B376C28A7, OS:9.0, name:iPhone 5 }
    #
    # We don't want to deal with that, so we just use the UDID

    class Device
      attr_accessor :name
      attr_accessor :udid
      attr_accessor :os_type
      attr_accessor :os_version
      attr_accessor :ios_version # Preserved for backwards compatibility
      attr_accessor :state
      attr_accessor :is_simulator

      def initialize(name: nil, udid: nil, os_type: nil, os_version: nil, state: nil, is_simulator: nil)
        self.name = name
        self.udid = udid
        self.os_type = os_type
        self.os_version = os_version
        self.ios_version = os_version
        self.state = state
        self.is_simulator = is_simulator
      end

      def to_s
        self.name
      end

      def reset
        UI.message("Resetting #{self}")
        `xcrun simctl shutdown #{self.udid}` if self.state == "Booted"
        `xcrun simctl erase #{self.udid}`
        return
      end
    end
  end

  class Simulator
    class << self
      def all
        return DeviceManager.simulators('iOS')
      end

      # Reset all simulators of this type
      def reset_all
        all.each(&:reset)
      end

      def reset_all_by_version(os_version: nil)
        return false unless os_version
        all.select { |device| device.os_version == os_version }.each(&:reset)
      end

      # Reset simulator by UDID or name and OS version
      # Latter is useful when combined with -destination option of xcodebuild
      def reset(udid: nil, name: nil, os_version: nil)
        match = all.detect { |device| device.udid == udid || device.name == name && device.os_version == os_version }
        match.reset if match
      end

      def clear_cache
        @devices = nil
      end

      def launch(device)
        return unless device.is_simulator

        simulator_path = File.join(Helper.xcode_path, 'Applications', 'Simulator.app')

        UI.verbose "Launching #{simulator_path} for device: #{device.name} (#{device.udid})"

        Helper.backticks("open -a #{simulator_path} --args -CurrentDeviceUDID #{device.udid}", print: FastlaneCore::Globals.verbose?)
      end

      def copy_logs(device, log_identity, logs_destination_dir)
        logs_destination_dir = File.expand_path(logs_destination_dir)
        os_version = FastlaneCore::CommandExecutor.execute(command: 'sw_vers -productVersion', print_all: false, print_command: false)

        if Gem::Version.new(os_version) >= Gem::Version.new('10.12.0')
          copy_logarchive(device, log_identity, logs_destination_dir)
        else
          copy_logfile(device, log_identity, logs_destination_dir)
        end
      end

      private

      def copy_logfile(device, log_identity, logs_destination_dir)
        logfile_src = File.expand_path("~/Library/Logs/CoreSimulator/#{device.udid}/system.log")
        return unless File.exist?(logfile_src)

        FileUtils.mkdir_p(logs_destination_dir)
        logfile_dst = File.join(logs_destination_dir, "system-#{log_identity}.log")

        FileUtils.rm_f(logfile_dst)
        FileUtils.cp(logfile_src, logfile_dst)
        UI.success "Copying file '#{logfile_src}' to '#{logfile_dst}'..."
      end

      def copy_logarchive(device, log_identity, logs_destination_dir)
        sim_resource_dir = FastlaneCore::CommandExecutor.execute(command: "xcrun simctl getenv #{device.udid} SIMULATOR_SHARED_RESOURCES_DIRECTORY 2>/dev/null", print_all: false, print_command: true)
        logarchive_src = File.join(sim_resource_dir, "system_logs.logarchive")
        logarchive_dst = File.join(logs_destination_dir, "system_logs-#{log_identity}.logarchive")

        # if logarchive already exists it fails as the .logarchive is a directory, so delete it. to be sure its gone
        FileUtils.rm_rf(logarchive_src)
        FileUtils.rm_rf(logarchive_dst)

        command = "xcrun simctl spawn #{device.udid} log collect 2>/dev/null"
        FastlaneCore::CommandExecutor.execute(command: command, print_all: false, print_command: true)

        FileUtils.mkdir_p(logarchive_dst)
        FileUtils.cp_r("#{logarchive_src}/.", logarchive_dst)
        UI.success "Copying file '#{logarchive_src}' to '#{logarchive_dst}'..."
      end
    end
  end

  class SimulatorTV < Simulator
    class << self
      def all
        return DeviceManager.simulators('tvOS')
      end
    end
  end

  class SimulatorWatch < Simulator
    class << self
      def all
        return DeviceManager.simulators('watchOS')
      end
    end
  end
end
