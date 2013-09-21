module Fluent

require 'fluent/mixin/config_placeholders'

class SwiftOutput < Fluent::TimeSlicedOutput
  Fluent::Plugin.register_output('swift', self)

  def initialize
    super
    require 'fog'
    require 'zlib'
    require 'time'
    require 'tempfile'
    require 'open3'
  end
  
  config_param :path, :string, :default => ""
  config_param :time_format, :string, :default => nil

  include SetTagKeyMixin
  config_set_default :include_tag_key, false

  include SetTimeKeyMixin
  config_set_default :include_time_key, false

  config_param :auth_url, :string
  config_param :auth_user, :string
  config_param :auth_tenant, :string, :default => nil
  config_param :auth_api_key, :string
  config_param :swift_account, :string, :default => nil
  config_param :swift_container, :string
  config_param :swift_object_key_format, :string, :default => "%{path}%{time_slice}_%{index}.%{file_extension}"
  config_param :store_as, :string, :default => "gzip"
  config_param :auto_create_container, :bool, :default => true
  config_param :check_apikey_on_start, :bool, :default => true
  config_param :proxy_uri, :string, :default => nil
  config_param :ssl_verify, :bool, :default => true

#  attr_reader :container
  
  include Fluent::Mixin::ConfigPlaceholders

  def placeholders
    [:percent]
  end

  def configure(conf)
    super

    if format_json = conf['format_json']
      @format_json = true
    else
      @format_json = false
    end

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

    @timef = TimeFormatter.new(@time_format, @localtime)

    if @localtime
      @path_slicer = Proc.new {|path|
        Time.now.strftime(path)
      }
    else
      @path_slicer = Proc.new {|path|
        Time.now.utc.strftime(path)
      }
    end
  end

  def start
    super

    Excon.defaults[:ssl_verify_peer] = @ssl_verify

    @storage = Fog::Storage.new :provider => 'OpenStack',
                      :openstack_auth_url => @auth_url,
                      :openstack_username => @auth_user,
                      :openstack_tenant => @auth_tenant,
                      :openstack_api_key  => @auth_api_key
    @storage.change_account @swift_account if @swift_account

    check_container
  end

  def format(tag, time, record)
    if @include_time_key || !@format_json
      time_str = @timef.format(time)
    end

    # copied from each mixin because current TimeSlicedOutput can't support mixins.
    if @include_tag_key
      record[@tag_key] = tag
    end
    if @include_time_key
      record[@time_key] = time_str
    end

    if @format_json
      Yajl.dump(record) + "\n"
    else
      "#{time_str}\t#{tag}\t#{Yajl.dump(record)}\n"
    end
  end

  def write(chunk)
    i = 0

    begin
      path = @path_slicer.call(@path)
      values_for_swift_object_key = {
        "path" => path,
        "time_slice" => chunk.key,
        "file_extension" => @ext,
        "index" => i
      }
      swift_path = @swift_object_key_format.gsub(%r(%{[^}]+})) { |expr|
        values_for_swift_object_key[expr[2...expr.size-1]]
      }
      i += 1
    end while check_object_exists(@swift_container, swift_path)

    tmp = Tempfile.new("swift-")
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
      end
      $log.info "Put Log to Swift. container=#{@swift_container} object=#{swift_path}"
    ensure
      tmp.close(true) rescue nil
      w.close rescue nil
      w.unlink rescue nil
    end
  end

  private

  def check_container
    begin
      @storage.get_container(@swift_container)
    rescue Fog::Storage::OpenStack::NotFound
      if @auto_create_container
        $log.info "Creating container #{@swift_container} on #{@auth_url}, #{@swift_account}"
        @storage.put_container(@swift_container)
      else
        raise "The specified container does not exist: container = #{swift_container}"
      end
    end
  end

  def check_object_exists(container, object)
    begin
      @storage.head_object(container, object)
    rescue Fog::Storage::OpenStack::NotFound
      return false
    end
    return true
  end

end
end
