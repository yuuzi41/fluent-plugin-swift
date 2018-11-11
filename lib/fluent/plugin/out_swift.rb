require 'fluent/plugin/output'
require 'fluent/timezone'
require 'fog/openstack'
require 'zlib'
require 'time'
require 'tempfile'
require 'open3'

module Fluent::Plugin
  class SwiftOutput < Output
    Fluent::Plugin.register_output('swift', self)

    helpers :compat_parameters, :formatter, :inject

    def initialize
      super
      @uuid_flush_enabled = false
    end

    desc "Path prefix of the files on Swift"
    config_param :path, :string, :default => ""
    config_param :auth_url, :string
    config_param :auth_user, :string
    config_param :auth_api_key, :string
    # identity v2
    config_param :auth_tenant, :string, :default => nil
    # identity v3
    config_param :project_name, :string, :default => nil
    config_param :domain_name, :string, :default => nil
    #
    config_param :auth_region, :string, :default => nil
    config_param :swift_account, :string, :default => nil
    desc "Swift container name"
    config_param :swift_container, :string
    desc "Archive format on Swift"
    config_param :store_as, :string, :default => "gzip"
    desc "If false, the certificate of endpoint will not be verified"
    config_param :ssl_verify, :bool, :default => true
    desc "The format of Swift object keys"
    config_param :swift_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
    desc "Create Swift container if it does not exists"
    config_param :auto_create_container, :bool, :default => true
    config_param :check_apikey_on_start, :bool, :default => true
    desc "URI of proxy environment"
    config_param :proxy_uri, :string, :default => nil
    desc "The length of `%{hex_random}` placeholder(4-16)"
    config_param :hex_random_length, :integer, default: 4
    desc "`sprintf` format for `%{index}`"
    config_param :index_format, :string, default: "%d"
    desc "Overwrite already existing path"
    config_param :overwrite, :bool, default: false

    DEFAULT_FORMAT_TYPE = "out_file"

    config_section :format do
      config_set_default :@type, DEFAULT_FORMAT_TYPE
    end

    config_section :buffer do
      config_set_default :chunk_keys, ['time']
      config_set_default :timekey, (60 * 60 * 24)
    end

#    attr_reader :storage

    MAX_HEX_RANDOM_LENGTH = 16

    def configure(conf)
      compat_parameters_convert(conf, :buffer, :formatter, :inject)

      super

    @ext, @mime_type = case @store_as
      when 'gzip' then ['gz', 'application/x-gzip']
      when 'lzo' then
        begin
          Open3.capture3('lzop -V')
        rescue Errno::ENOENT
          raise ConfigError, "'lzop' utility must be in PATH for LZO compression"
        end
        ['lzo', 'application/x-lzop']
      when 'json' then ['json', 'application/json']
      else ['txt', 'text/plain']
    end

      @formatter = formatter_create

      if @hex_random_length > MAX_HEX_RANDOM_LENGTH
        raise Fluent::ConfigError, "hex_random_length parameter must be less than or equal to #{MAX_HEX_RANDOM_LENGTH}"
      end

      unless @index_format =~ /^%(0\d*)?[dxX]$/
        raise Fluent::ConfigError, "index_format parameter should follow `%[flags][width]type`. `0` is the only supported flag, and is mandatory if width is specified. `d`, `x` and `X` are supported types" 
      end

      @swift_object_key_format = process_swift_object_key_format
      # For backward compatibility
      # TODO: Remove time_slice_format when end of support compat_parameters
      @configured_time_slice_format = conf['time_slice_format']
      @values_for_swift_object_chunk = {}
      @time_slice_with_tz = Fluent::Timezone.formatter(@timekey_zone, @configured_time_slice_format || timekey_to_timeformat(@buffer_config['timekey']))
    end

    def multi_workers_ready?
      true
    end

    def start

      Excon.defaults[:ssl_verify_peer] = @ssl_verify

      begin
        @storage = Fog::OpenStack::Storage.new(openstack_auth_url: @auth_url,
                      openstack_username: @auth_user,
                      openstack_project_name: @project_name,
                      openstack_domain_name: @domain_name,
                      openstack_api_key: @auth_api_key,
                      openstack_region: @auth_region)
#      rescue Fog::OpenStack::Storage::NotFound
        # ignore NoSuchBucket Error because ensure_bucket checks it.
      rescue => e
        raise "can't call Swift API. Please check your credentials or auth_url configuration. error = #{e.inspect}"
      end

      @storage.change_account @swift_account if @swift_account

      check_container

      super
    end

    def format(tag, time, record)
      r = inject_values_to_record(tag, time, record)
      @formatter.format(tag, time, r)
    end

    def write(chunk)
      i = 0
      metadata = chunk.metadata
      previous_path = nil
      time_slice = if metadata.timekey.nil?
                     ''.freeze
                   else
                     @time_slice_with_tz.call(metadata.timekey)
                   end

      begin
        @values_for_swift_object_chunk[chunk.unique_id] ||= {
            "%{hex_random}" => hex_random(chunk),
        }
        values_for_swift_object_key_pre = {
          "%{path}" => @path,
          "%{file_extension}" => @ext,
        }
        values_for_swift_object_key_post = {
          "%{time_slice}" => time_slice,
          "%{index}" => sprintf(@index_format,i),
        }.merge!(@values_for_swift_object_chunk[chunk.unique_id])
          values_for_swift_object_key_post["%{uuid_flush}".freeze] = uuid_random if @uuid_flush_enabled

        swift_path = @swift_object_key_format.gsub(%r(%{[^}]+})) do |matched_key|
            values_for_swift_object_key_pre.fetch(matched_key, matched_key)
          end

          swift_path = extract_placeholders(swift_path, metadata)
          swift_path = swift_path.gsub(%r(%{[^}]+}), values_for_swift_object_key_post)
          if (i > 0) && (swift_path == previous_path)
            if @overwrite
              log.warn "#{swift_path} already exists, but will overwrite"
              break
            else
              raise "duplicated path is generated. use %{index} in swift_object_key_format: path = #{swift_path}"
            end
          end


        i += 1
        previous_path = swift_path
      end while check_object_exists(@swift_container, swift_path)


      tmp = Tempfile.new("swift-")
      tmp.binmode
      begin
        if @store_as == "gzip"
          w = Zlib::GzipWriter.new(tmp)
          chunk.write_to(w)
          w.close
        elsif @store_as == "lzo"
          w = Tempfile.new("chunk-tmp")
          chunk.write_to(w)
          w.close
          tmp.close
          # We don't check the return code because we can't recover lzop failure.
          system "lzop -qf1 -o #{tmp.path} #{w.path}"
        else
          chunk.write_to(tmp)
          tmp.close
        end
        File.open(tmp.path) do |file|
          @storage.put_object(@swift_container, swift_path, file, {:content_type => @mime_type})
        @values_for_swift_object_chunk.delete(chunk.unique_id)
        end
        # log.debu "out_swift: write chunk #{dump_unique_id_hex(chunk.unique_id)} with metadata #{chunk.metadata} to swift://#{@swift_container}/#{swift_path}"
#        $log.info "out_swift: Put Log to Swift. container=#{@swift_container} object=#{swift_path}"
      ensure
        tmp.close(true) rescue nil
        w.close rescue nil
        w.unlink rescue nil
      end
    end

    private

    def hex_random(chunk)
      unique_hex = Fluent::UniqueId.hex(chunk.unique_id)
      unique_hex.reverse! # unique_hex is like (time_sec, time_usec, rand) => reversing gives more randomness
      unique_hex[0...@hex_random_length]
    end

    def uuid_random
      ::UUIDTools::UUID.random_create.to_s
    end

    # This is stolen from Fluentd
    def timekey_to_timeformat(timekey)
      case timekey
      when nil          then ''
      when 0...60       then '%Y%m%d%H%M%S' # 60 exclusive
      when 60...3600    then '%Y%m%d%H%M'
      when 3600...86400 then '%Y%m%d%H'
      else                   '%Y%m%d'
      end
    end

    def check_container
      begin
        @storage.get_container(@swift_container)
      rescue Fog::OpenStack::Storage::NotFound
        if @auto_create_container
          $log.info "Creating container #{@swift_container} on #{@auth_url}, #{@swift_account}"
          @storage.put_container(@swift_container)
        else
          raise "The specified container does not exist: container = #{swift_container}"
        end
      end
    end

    def process_swift_object_key_format
      %W(%{uuid} %{uuid:random} %{uuid:hostname} %{uuid:timestamp}).each { |ph|
        if @swift_object_key_format.include?(ph)
          raise Fluent::ConfigError, %!#{ph} placeholder in swift_object_key_format is removed!
        end
      }

      if @swift_object_key_format.include?('%{uuid_flush}')
        # test uuidtools works or not
        begin
          require 'uuidtools'
        rescue LoadError
          raise Fluent::ConfigError, "uuidtools gem not found. Install uuidtools gem first"
        end
        begin
          uuid_random
        rescue => e
          raise Fluent::ConfigError, "Generating uuid doesn't work. Can't use %{uuid_flush} on this environment. #{e}"
        end
        @uuid_flush_enabled = true
      end

      @swift_object_key_format.gsub('%{hostname}') { |expr|
        log.warn "%{hostname} will be removed in the future. Use \"\#{Socket.gethostname}\" instead"
        Socket.gethostname
      }
    end

    def check_object_exists(container, object)
      begin
        @storage.head_object(container, object)
      rescue Fog::OpenStack::Storage::NotFound
        return false
      end
      return true
    end

  end
end
