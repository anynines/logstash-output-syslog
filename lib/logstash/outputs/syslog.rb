# frozen_string_literal: true

require 'logstash/outputs/base'
require 'logstash/namespace'
require 'date'
require 'logstash/codecs/plain'

# Send events to a syslog server.
#
# You can send messages compliant with RFC3164 or RFC5424
# using either UDP or TCP as the transport protocol.
#
# By default the contents of the `message` field will be shipped as
# the free-form message text part of the emitted syslog message. If
# your messages don't have a `message` field or if you for some other
# reason want to change the emitted message, modify the `message`
# configuration option.
module LogStash
  module Outputs
    class Syslog < LogStash::Outputs::Base
      config_name 'syslog'

      FACILITY_LABELS = [
        'kernel',
        'user-level',
        'mail',
        'daemon',
        'security/authorization',
        'syslogd',
        'line printer',
        'network news',
        'uucp',
        'clock',
        'ftp',
        'ntp',
        'log audit',
        'log alert',
        'local0',
        'local1',
        'local2',
        'local3',
        'local4',
        'local5',
        'local6',
        'local7'
      ].freeze

      SEVERITY_LABELS = %w[
        emergency
        alert
        critical
        error
        warning
        notice
        informational
        debug
      ].freeze

      CRL_END_TAG = "\n-----END X509 CRL-----\n"

      # syslog server address to connect to
      config :host, validate: :string, required: true

      # syslog server port to connect to
      config :port, validate: :number, required: true

      # when connection fails, retry interval in sec.
      config :reconnect_interval, validate: :number, default: 1

      # syslog server protocol. you can choose between udp, tcp and ssl/tls over tcp
      config :protocol, validate: %w[tcp udp ssl-tcp], default: 'udp'

      # Verify the identity of the other end of the SSL connection against the CA.
      config :ssl_verify, validate: :boolean, default: false

      # The SSL CA certificate, chainfile or CA path. The system CA path is automatically included.
      config :ssl_cacert, validate: :path

      # CRL file or bundle of CRLs
      config :ssl_crl, validate: :path

      # Check CRL for only leaf certificate (false) or require CRL check for the complete chain (true)
      config :ssl_crl_check_all, validate: :boolean, default: false

      # use label parsing for severity and facility levels
      # use priority field if set to false
      config :use_labels, validate: :boolean, default: true

      # syslog priority
      # The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :priority, validate: :string, default: '%<syslog_pri>s'

      # facility label for syslog message
      # default fallback to user-level as in rfc3164
      # The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :facility, validate: :string, default: 'user-level'

      # severity label for syslog message
      # default fallback to notice as in rfc3164
      # The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :severity, validate: :string, default: 'notice'

      # source host for syslog message. The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :sourcehost, validate: :string, default: '%<host>s'

      # application name for syslog message. The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :appname, validate: :string, default: 'LOGSTASH'

      # process id for syslog message. The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :procid, validate: :string, default: '-'

      # message text to log. The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :message, validate: :string, default: '%<message>s'

      # message id for syslog message. The new value can include `%{foo}` strings
      # to help you build a new value from other parts of the event.
      config :msgid, validate: :string, default: '-'

      # syslog message format: you can choose between rfc3164 or rfc5424
      config :rfc, validate: %w[rfc3164 rfc5424 rfc6587], default: 'rfc3164'

      # RFC5424 structured data.
      config :structured_data, validate: :string, default: ''

      def register
        @client_socket = nil

        @ssl_context = setup_ssl if ssl?

        if @codec.instance_of?(::LogStash::Codecs::Plain) && @codec.config['format'].nil?
          @codec = LogStash::Codecs::Plain.new({ 'format' => @message })
        end
        @codec.on_event(&method(:publish))

        # use instance variable to avoid string comparison for each event
        @is_rfc3164 = (@rfc == 'rfc3164')
        @is_rfc6587 = (@rfc == 'rfc6587')

        @delimitter = "\n"
        @delimitter = '' if @is_rfc6587
        return unless @is_rfc3164 && !@structured_data.empty?

        raise LogStash::ConfigurationError, 'Structured data is not supported for RFC3164'
      end

      def receive(event)
        @codec.encode(event)
      end

      def publish(event, payload)
        appname = event.sprintf(@appname)
        procid = event.sprintf(@procid)
        sourcehost = event.sprintf(@sourcehost)

        message = payload.to_s.rstrip.gsub(/\r\n/, "\n").gsub(/\n/, '\n')

        # fallback to pri 13 (facility 1, severity 5)
        if @use_labels
          facility_code = FACILITY_LABELS.index(event.sprintf(@facility)) || 1
          severity_code = SEVERITY_LABELS.index(event.sprintf(@severity)) || 5
          priority = (facility_code * 8) + severity_code
        else
          priority = begin
            Integer(event.sprintf(@priority))
          rescue StandardError
            13
          end
          priority = 13 if priority.negative? || priority > 191
        end

        if @is_rfc3164
          timestamp = event.sprintf('%{+MMM dd HH:mm:ss}')
          syslog_msg = "<#{priority}>#{timestamp} #{sourcehost} #{appname}[#{procid}]: #{message}"
        else
          msgid = event.sprintf(@msgid)
          sd = @structured_data.empty? ? '-' : event.sprintf(@structured_data)
          timestamp = event.sprintf("%{+YYYY-MM-dd'T'HH:mm:ss.SSSZZ}")
          syslog_msg = "<#{priority}>1 #{timestamp} #{sourcehost} #{appname} #{procid} #{msgid} #{sd} #{message}"
          syslog_msg = "#{syslog_msg.length} #{syslog_msg}" if @is_rfc6587
        end

        begin
          @client_socket ||= connect
          @client_socket.write(syslog_msg + @delimitter)
        rescue StandardError => e
          # We don't expect udp connections to fail because they are stateless, but ...
          # udp connections may fail/raise an exception if used with localhost/127.0.0.1
          return if udp?

          @logger.warn("syslog #{@protocol} output exception: closing, reconnecting and resending event",
                       host: @host, port: @port, exception: e, backtrace: e.backtrace, event: event)
          begin
            @client_socket.close
          rescue StandardError
            nil
          end
          @client_socket = nil

          sleep(@reconnect_interval)
          retry
        end
      end

      private

      def udp?
        @protocol == 'udp'
      end

      def ssl?
        @protocol == 'ssl-tcp'
      end

      def connect
        socket = nil
        if udp?
          socket = UDPSocket.new
          socket.connect(@host, @port)
        else
          socket = TCPSocket.new(@host, @port)
          if ssl?
            socket = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
            # Use SNI extension
            socket.hostname = @host
            begin
              socket.connect
            rescue OpenSSL::SSL::SSLError => e
              @logger.error('SSL Error', exception: e,
                                         backtrace: e.backtrace)
              # NOTE(mrichar1): Hack to prevent hammering peer
              sleep(5)
              raise
            end
          end
        end
        socket
      end

      def setup_ssl
        require 'openssl'
        ssl_context = OpenSSL::SSL::SSLContext.new

        if @ssl_verify
          cert_store = OpenSSL::X509::Store.new
          # Load the system default certificate path to the store
          cert_store.set_default_paths
          if ::File.directory?(@ssl_cacert)
            cert_store.add_path(@ssl_cacert)
          else
            cert_store.add_file(@ssl_cacert)
          end
          if @ssl_crl
            # copy the behavior of X509_load_crl_file() which supports loading bundles of CRLs.
            ::File.read(@ssl_crl).split(CRL_END_TAG).each do |crl|
              crl << CRL_END_TAG
              cert_store.add_crl(OpenSSL::X509::CRL.new(crl))
            end
            cert_store.flags = @ssl_crl_check_all ? OpenSSL::X509::V_FLAG_CRL_CHECK | OpenSSL::X509::V_FLAG_CRL_CHECK_ALL : OpenSSL::X509::V_FLAG_CRL_CHECK
          end
          ssl_context.cert_store = cert_store
          ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end
        ssl_context
      end
    end
  end
end
