require 'net/protocol'
require 'strscan'
require 'yaml'
require 'logger'

module Net
  class IRC < Protocol
    include Enumerable

    class << self
      def logger
        @logger ||= Logger.new('net-irc.log')
      end

      def logger=(logger)
        @logger = logger
      end
    end

    USER_MODE_DEFAULT = 0
    USER_MODE_RECEIVE_WALLOPS = 4
    USER_MODE_INVISIBLE = 8

    PORT_DEFAULT = 6667

    VERSION = "0.9.3"

    class CTCP
      attr_accessor :source, :target, :keyword, :parameters

      CTCP_REGEX = /\001(.*?)\001/

      def initialize(keyword, *parameters)
        @source = nil
        @keyword = keyword
        @parameters = parameters
      end

      def to_s
        str = "\001#{keyword}"
        str << parameters.collect { |p| " #{p}"}.join
        str << "\001"
      end

      class << self
        def parse(text)
          [
            text.gsub(CTCP_REGEX, ''),
            text.scan(CTCP_REGEX).flatten.collect do |message|
              parameters = message.split(' ')
              case keyword = parameters.shift
              when 'VERSION'
                CTCPVersion.new(*parameters)
              when 'PING'
                CTCPPing.new(*parameters)
              when 'CLIENTINFO'
                CTCPClientinfo.new(*parameters)
              when 'ACTION'
                CTCPAction.new(*parameters)
              when 'FINGER'
                CTCPFinger.new(*parameters)
              when 'TIME'
                CTCPTime.new(*parameters)
              when 'DCC'
                CTCPDcc.new(*parameters)
              when 'ERRMSG'
                CTCPErrmsg.new(*parameters)
              when 'PLAY'
                CTCPPlay.new(*parameters)
              else
                CTCP.new(keyword, *parameters)
              end
            end
          ]
        end
      end
    end

    class CTCPVersion < CTCP
      def initialize(*parameters)
        super('VERSION', parameters)
      end
    end

    class CTCPPing < CTCP
      attr_accessor :arg

      def initialize(arg = nil)
        if @arg = arg
          super('PING', arg)
        else
          super('PING')
        end
      end
    end

    class CTCPClientinfo < CTCP
      def initialize(*keywords)
        super('CLIENTINFO', *keywords)
      end
    end

    class CTCPAction < CTCP
      attr_accessor :text

      def initialize(*parameters)
        @text = parameters.join(' ')

        super('ACTION', *parameters)
      end
    end

    class CTCPFinger < CTCP
      def initialize(text = nil)
        super('FINGER', text)
      end
    end

    class CTCPTime < CTCP
      attr_accessor :time
      def initialize(*parameters)
        @time = parameters.join(' ')

        super('TIME', *parameters)
      end
    end

    class CTCPDcc < CTCP
      def initialize(type, protocol, ip, port, *args)
        super('DCC', type, protocol, ip, port, *args)
      end
    end

    class CTCPErrmsg < CTCP
      def initialize(keyword, text = nil)
        super('ERRMSG', keyword, text)
      end
    end

    class CTCPPlay < CTCP
      def initialize(filename, mime_type)
        super('PLAY', filename, mime_type)
      end
    end

    class Message
      attr_reader :prefix
      attr_accessor :command, :parameters

      COMMAND_MAPS = %w(rfc1459 rfc2812 isupport hybrid ircu hyperion)

      def initialize(*args)
        raise ArgumentError, "wrong number of arguments (#{args.size} for 2)" if args.size < 2

# puts ">>>>> args=#{args.inspect}"

        @prefix, @command, *parameters = args
# puts ">>>>> @prefix=#{@prefix.inspect}, command=#{@command.inspect}, parameters=#{parameters.inspect}"
        @parameters = Array(parameters)
      end

      class Prefix
        attr_accessor :prefix

        PREFIX_REGEX = /^([^!@]+)(?:(?:!([^@]+))?@(.+))?/

        def initialize(prefix)
          @prefix = prefix
          @matches = prefix.match(PREFIX_REGEX)
        end

        def server
          @prefix
        end

        def nickname
          @matches[1]
        end

        def user
          @matches[2]
        end

        def host
          @matches[3]
        end

        def to_s
          @prefix
        end
      end

      def prefix=(value)
        @prefix = value && Prefix.new(value)
      end

      def prefix?
        @prefix
      end

      def to_s
# puts ">>>>> prefix=#{prefix.inspect}, command=#{command.inspect}, parameters=#{parameters.inspect}"
        str = prefix ? ":#{prefix} " : ""
        str << command
        if ! parameters.empty?
          parameters[0..-2].each do |param|
            str << " #{param}"
          end
          if parameters.last =~ /^:| /
            str << " :#{parameters.last}"
          else
            str << " #{parameters.last}"
          end
        end
        str
      end

      def write(socket)
        line = to_s
        IRC.logger.debug ">>>>> #{line.inspect}"
        socket.writeline(line)
      end

      class << self
        def parse(line)
          scanner = StringScanner.new(line)

          prefix = scanner.scan(/:([^ ]+) /) && scanner[1]
          command = scanner.scan(/[[:alpha:]]+|\d{3}/)
          params = []
          14.times do
            break if ! scanner.scan(/ ([^ :][^ ]*)/)
            params << scanner[1]
          end
          params << scanner[1] if scanner.scan(/ :(.+)/)

          message = nil
          command_name = command.to_i > 0 ? command_for_number(command.to_i) : command

          if command_name
            message_type = "#{command_name.downcase.split('_').collect { |w| w.capitalize }.join}"
            if Net::IRC.const_defined?(message_type)
              # puts "creating a #{message_type} object with params: #{params.join(', ')}"
              message_type = Net::IRC.const_get(message_type)
              message = message_type.new(*params)
              message.prefix = prefix
            end
          end

          message ||= Message.new(prefix, command_name || command, *params)
        end

        def command_for_number(number)
          @command_map ||= COMMAND_MAPS.inject({}) { |merged,map| merged.merge!(YAML.load_file("#{File.dirname(__FILE__)}/#{map}.yml")) }
          @command_map[number]
        end
      end
    end

    class Reply < Message
      attr_accessor :text

      def initialize(prefix, command, *args)
        args.pop unless @text = args.last
        super(nil, command, *args)
      end
    end

    class ReplyWithTarget < Reply
      attr_accessor :target

      def initialize(prefix, command, target, *args)
        @target = target
        super(prefix, command, @target, *args)
      end
    end

    # 001 <target> :Welcome to the Internet Relay Network <nick>!<user>@<host>
    class RplWelcome < ReplyWithTarget
      def initialize(target, text)
        super(nil, 'RPL_WELCOME', target, text)
      end
    end

    # 002 <target> :Your host is <servername>, running version <ver>
    class RplYourhost < Reply
      def initialize(target, text)
        super(nil, 'RPL_YOURHOST', target, text)
      end
    end

    # 003 <target> :This server was created <date>
    class RplCreated < ReplyWithTarget
      def initialize(target, text)
        super(nil, 'RPL_CREATED', target, text)
      end
    end

    # 004 <target> <servername> <version> <available user modes> <available channel modes>
    class RplMyinfo < ReplyWithTarget
      attr_accessor :servername, :version, :available_user_modes, :available_channel_modes, :not_sure_what

      def initialize(target, servername, version, available_user_modes, available_channel_modes, not_sure_what = nil)
        @servername = servername
        @version = version
        @available_user_modes = available_user_modes
        @available_channel_modes = available_channel_modes
        @not_sure_what = not_sure_what

        super(nil, 'RPL_MYINFO', target, servername, version, available_user_modes, available_channel_modes, nil)
      end
    end

    # 005 <target> ( [ "-" ] <parameter> ) | ( <parameter> "=" [ <value> ] ) *( ( [ "-" ] <parameter> ) | ( <parameter> "=" [ <value> ] ) ) :are supported by this server
    class RplIsupport < ReplyWithTarget
      class Parameter
        PARAMETER_REGEX = /^(-)?([[:alnum:]]{1,20})(?:=(.*))?/

        def initialize(param)
          @param = param
          @matches = param.match(PARAMETER_REGEX)
        end

        def name
          @matches[2]
        end

        def value
          @matches[3] || @matches[1].nil?
        end
      end

      def initialize(target, *args)
        raise ArgumentError, "wrong number of arguments (#{1 + args.size} for 3)" if args.size < 2

        @parameters = args[0..-2].collect { |p| Parameter.new(p) }

        super(nil, 'RPL_ISUPPORT', target, *args)
      end
    end

    # 250 <target> :<text>
    class RplStatsconn < ReplyWithTarget
      def initialize(target, text)
        super(nil, 'RPL_LSTATSCONN', target, text)
      end
    end

    # 251 <target> :<text>
    class RplLuserclient < ReplyWithTarget
      def initialize(target, text)
        super(nil, 'RPL_LUSERCLIENT', target, text)
      end
    end

    class ReplyWithCount < ReplyWithTarget
      attr_accessor :count

      def initialize(prefix, command, target, count, text)
        @count = count
        super(prefix, command, target, count, text)
      end
    end

    # 252 <target> <count> :<text>
    class RplLuserop < ReplyWithCount
      def initialize(target, count, text)
        super(nil, 'RPL_LUSEROP', target, count, text)
      end
    end

    # 254 <target> <count> :<text>
    class RplLuserchannels < ReplyWithCount
      def initialize(target, count, text)
        super(nil, 'RPL_LUSERCHANNELS', target, count, text)
      end
    end

    # 255 <target> :<text>
    class RplLuserme < ReplyWithTarget
      def initialize(target, text)
        super(nil, 'RPL_LUSERME', target, text)
      end
    end

    # 265 <target> :<text>
    class RplLocalusers < ReplyWithTarget
      def initialize(target, *text)
        super(nil, 'RPL_LOCALUSERS', target, text.join(' '))
      end
    end

    # 266 <target> :<text>
    class RplGlobalusers < ReplyWithTarget
      def initialize(target, *text)
        super(nil, 'RPL_GLOBALUSERS', target, text.join(' '))
      end
    end

    class ReplyWithChannel < ReplyWithTarget
      attr_accessor :channel

      def initialize(prefix, command, target, channel, *args)
        @channel = channel
        super(prefix, command, target, @channel, *args)
      end
    end

    # 332 <target> <target> <channel> :<text>
    class RplTopic < ReplyWithChannel
      def initialize(target, channel, text)
        super(nil, 'RPL_TOPIC', target, channel, text)
      end
    end

    # 333 <target> <channel> <nickname> <time>
    class RplTopicwhotime < ReplyWithChannel
      attr_accessor :nickname, :time

      def initialize(target, channel, nickname, time)
        @nickname = nickname
        @time = Time.at(time.to_i)
        super(nil, 'RPL_TOPICWHOTIME', target, channel, nickname, time, nil)
      end
    end

    # 353 <target> ( "=" | "*" | "@" ) <channel> :[ "@" | "+" ] <nick> *( " " [ "@" / "+" ] <nick> )
    class RplNamreply < Reply
      attr_accessor :channel_type, :channel, :names

      def initialize(target, channel_type, channel, names)
        @channel_type = channel_type
        @channel = channel
        @names = names.split(' ')
        super(nil, 'RPL_NAMREPLY', target, @channel_type, @channel, names, nil)
      end
    end

    # 366 <target> <channel> :End of /NAMES list
    class RplEndofnames < ReplyWithChannel
      def initialize(target, channel, text)
        super(nil, 'RPL_ENDOFNAMES', target, channel, text)
      end
    end

    # 372 <target> :- <text>
    class RplMotd < Reply
      def initialize(target, text)
        super(nil, 'RPL_MOTD', target, text)
      end
    end

    # 375 <target> :- <server> Message of the day -
    class RplMotdstart < Reply
      def initialize(target, text)
        super(nil, 'RPL_MOTDSTART', target, text)
      end
    end

    # 376 <target> :End of MOTD command.
    class RplEndofmotd < Reply
      def initialize(target, text)
        super(nil, 'RPL_ENDOFMOTD', target, text)
      end
    end

    class Error < ReplyWithTarget
    end

    # 422 <target> <nickname> :Nickname is already in use.
    class ErrNicknameinuse < Error
      attr_accessor :nickname

      def initialize(target, nickname, text)
        @nickname = nickname

        super(nil, 'ERR_NICKNAMEINUSE', target, @nickname, text)
      end
    end

    # 477 <target> <channel> :<text>
    class ErrNeedreggednick < Error
      attr_accessor :channel

      def initialize(target, channel, text)
        @channel = channel

        super(nil, 'ERR_NEEDREGGEDNICK', target, channel, text)
      end
    end

    # 901 <target> <id> <username> <hostname> :You are now logged in. (id <id>, username <username>, hostname <hostname>)
    class ReplyWithRegistryParameters < ReplyWithTarget
      attr_accessor :id, :username, :hostname

      def initialize(prefix, command, target, id, username, hostname, text)
        @id = id
        @username = username
        @hostname = hostname

        super(prefix, command, target, id, username, hostname, text)
      end
    end

    # 901 <target> <id> <username> <hostname> :You are now logged in. (id <id>, username <username>, hostname <hostname>)
    class RplLoggedin < ReplyWithRegistryParameters
      def initialize(target, id, username, hostname, text)
        super(nil, 'RPL_LOGGED_IN', target, id, username, hostname, text)
      end
    end

    # 902 <target> <id> <username> <hostname> :You are now logged out. (id <id>, username <username>, hostname <hostname>)
    class RplLoggedout < ReplyWithRegistryParameters
      def initialize(target, id, username, hostname, text)
        super(nil, 'RPL_LOGGED_OUT', target, id, username, hostname, text)
      end
    end


    # JOIN ( <channel> *( "," <channel> ) [ <key> *( "," <key> ) ] )
    #      / "0"
    class Join < Message
      attr_accessor :channels, :keys

      def initialize(channels, keys = nil)
        @channels = channels.split(',')
        @keys = keys && keys.split(',')

        if keys
          super(nil, 'JOIN', channels, keys)
        else
          super(nil, 'JOIN', channels)
        end
      end
    end

    # MODE <channel> *( ( "-" / "+" ) *<modes> *<modeparams> )
    class Mode < Message
      attr_accessor :channel, :modes

      def initialize(channel, *parameters)
        @channel = channel
        @modes = parameters.join(' ')

        super(nil, 'MODE', channel, *parameters)
      end
    end

    # NICK <nickname>
    class Nick < Message
      attr_accessor :nickname

      def initialize(nickname)
        @nickname = nickname

        super(nil, 'NICK', @nickname)
      end
    end

    # NOTICE <target> <text>
    class Notice < Message
      attr_accessor :target, :text, :ctcp

      def initialize(target, text)
        @target = target
        @text, @ctcp = CTCP.parse(text)

        super(nil, 'NOTICE', @target, text)
      end
    end

    # PART <channel> *( "," <channel> ) [ <text> ]
    class Part < Message
      attr_accessor :channels, :text

      def initialize(channels, message = nil)
        @channels = channels.split(',')

        if message
          super(nil, 'PART', channels, message)
        else
          super(nil, 'PART', channels)
        end
      end
    end

    # PASS <password>
    class Pass < Message
      attr_accessor :password

      def initialize(password)
        @password = password

        super(nil, 'PASS', @password)
      end
    end

    # PING <server> [ <target> ]
    class Ping < Message
      attr_accessor :server, :target

      def initialize(server, target = nil)
        @server = server

        if @target = target
          super(nil, 'PING', @server, @target)
        else
          super(nil, 'PING', @server)
        end
      end
    end

    # PONG <server> [ <target> ]
    class Pong < Message
      attr_accessor :server, :target

      def initialize(server, target = nil)
        @server = server

        if @target = target
          super(nil, 'PONG', @server, @target)
        else
          super(nil, 'PONG', @server)
        end
      end
    end

    # PRIVMSG <target> <text>
    class Privmsg < Message
      attr_accessor :target, :text, :ctcp

      def initialize(target, text)
        @target = target
        @text, @ctcp = CTCP.parse(text)

        super(nil, 'PRIVMSG', @target, text)
      end
    end

    # QUIT [ <text> ]
    class Quit < Message
      attr_accessor :text

      def initialize(text = nil)
        if @text = text
          super(nil, 'QUIT', @text)
        else
          super(nil, 'QUIT')
        end
      end
    end

    # USER <user> <mode> <unused> <realname>
    class User < Message
      attr_accessor :user, :realname, :mode

      def initialize(*args)
# puts ">>>>> User#initialize(#{args.inspect})"
        raise ArgumentError, "wrong number of arguments (#{args.size} for 2)" if args.size < 2
        raise ArgumentError, "wrong number of arguments (#{args.size} for 4)" if args.size > 4

        @user = args.shift

        # treat mode and "unused" as optional for convenience
        @mode = args.size > 1 && args.shift || USER_MODE_DEFAULT

        args.shift if args.size > 1

        @realname = args.shift

# puts ">>>>> @user=#{@user.inspect}, @mode=#{@mode.inspect}, unused=#{unused.inspect}, @realname=#{@realname.inspect}"
        super(nil, 'USER', @user, @mode, '*', @realname)
# puts ">>>>> prefix=#{prefix.inspect}, command=#{command.inspect}, parameters=#{parameters.inspect}"
      end
    end

    class << self
      def start(user, password, realname, address, port = nil, &block)
        new(address, port).start(user, password, realname, &block)
      end
    end

    def initialize(address, port = nil)
      @address = address
      @port = port || PORT_DEFAULT
      @started = false
      @socket = nil
    end

    def started?
      @started
    end

    def start(user, password, realname, nickname = nil)
      raise IOError, 'IRC session already started' if started?

      if block_given?
        begin
          do_start(user, password, realname, nickname)
          return yield(self)
        ensure
          do_finish
        end
      else
        do_start(user, password, realname, nickname)
        return self
      end
    end

    def finish
      raise IOError, 'IRC session not yet started' if ! started?
    end

    def each
      while line = @socket.readline
        IRC.logger.debug "<<<<< #{line.inspect}"

        message = Message.parse(line.chomp)

        if message.respond_to? :ctcp
          message.ctcp.each do |ctcp|
            ctcp.source = message.prefix.nickname
            ctcp.target = message.target

            yield ctcp
          end
          next if message.text.empty?
        end

        case message
        when Net::IRC::Ping
          pong message.server
        else
          yield message
        end
      end
    rescue IOError
      raise if started?
    end

    def ctcp(target, text)
      privmsg(target, "\001#{text}\001")
    end

    def ctcp_version(target, *parameters)
      notice(target, CTCPVersion.new(*parameters).to_s)
    end

    def ctcp_ping(target, arg = nil)
      notice(target, CTCPPing.new(arg).to_s)
    end

    def ctcp_time(target, time = nil)
      time ||= Time.now
      differential = '%.2d%.2d' % (time.utc_offset / 60).divmod(60)
      notice(target, CTCPTime.new(time.strftime("%a, %d %b %Y %H:%M #{differential}")).to_s)
    end

    def join(channels = nil)
      case channels
      when NilClass
        Join.new('0')
      when Hash
        Join.new(channels.keys.join(','), channels.values.join(','))
      when Array
        Join.new(channels.join(','))
      else
        Join.new(channels.to_s)
      end.write(@socket)
    end

    def nick(nickname)
      Nick.new(nickname).write(@socket)
    end

    def notice(target, text)
      Notice.new(target, text).write(@socket)
    end

    def part(channels, message = nil)
      if message
        Part.new(Array(channels).join(','), message)
      else
        Part.new(Array(channels).join(','))
      end.write(@socket)
    end

    def pass(password)
      Pass.new(password).write(@socket)
    end

    def pong(server, target = nil)
      Pong.new(server, target).write(@socket)
    end

    def privmsg(target, text)
      Privmsg.new(target, text).write(@socket)
    end

    def quit(text = nil)
      Quit.new(text).write(@socket)
    end

    def user(user, realname, mode = nil)
      User.new(user, mode || USER_MODE_DEFAULT, realname).write(@socket)
    end

    private
    def do_start(user, password, realname, nickname = nil)
      @socket = InternetMessageIO.old_open(@address, @port)
      pass(password) unless password.nil? || password.empty?
      nick(user)
      user(user, realname)
      @started = true
    ensure
      do_finish if ! started?
    end

    def do_finish
      quit if started?
    ensure
      @started = false
      @socket.close if @socket && ! @socket.closed?
      @socket = nil
    end
  end
end
