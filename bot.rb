#!/usr/bin/ruby
#
# nicl Copyright © 2007-2008 unwwwired.net
# Created by: S. Brent Faulkner (brentf@unwwwired.net) 2007-08-29
#

$: << File.join(File.dirname(__FILE__), 'lib')

require 'rubygems'
require File.join(File.dirname(__FILE__), 'net/irc')
require 'mlb_gameday_api'
require 'time'

module Ansi
  RESET = 0
  BOLD = 1
  DIM = 2
  UNDERSCORE = 4
  BLINK = 5
  REVERSE = 7
  HIDDEN = 8

  BLACK = 0
  RED = 1
  GREEN = 2
  YELLOW = 3
  BLUE = 4
  MAGENTA = 5
  CYAN = 6
  WHITE = 7

  def esc(*attrs)
    "\033[#{attrs.join(';')}m"
  end

  def fg(colour)
    30 + colour
  end

  def bg(colour)
    40 + colour
  end

  def highlight(text, *attrs)
    "#{esc(*attrs)}#{text}#{esc(RESET)}"
  end
end

include Ansi

begin
  require 'termios'
  # real implementation for toggling echo
  def echo(on = true)
    oldt = Termios.tcgetattr(STDIN)
    newt = oldt.dup
    newt.lflag &= ~Termios::ECHO
    Termios.tcsetattr(STDIN, Termios::TCSANOW, newt)

    # if no block is provided, return the original echo setting
    return (oldt.lflag & Termios::ECHO) == Termios::ECHO unless block_given?

    # otherwise yield to the block and restore the original echo setting
    ret = yield
    Termios.tcsetattr(STDIN, Termios::TCSANOW, oldt)
    ret
  end
rescue LoadError
  # minimal stub in case Termios is not installed
  def echo(on = true)
    return true unless block_given?
    yield
  end
end

def prompt(text, hidden = false)
  print text
  line = STDIN.readline.chomp
  print "\n"
  line
end

# TODO: a bit backwards... should probably be "Net::IRC.logger = logger"
logger = Net::IRC.logger

Net::IRC.logger.level = Logger::DEBUG
Net::IRC.logger.datetime_format = "%Y/%m/%d %H:%M:%S"

Thread.abort_on_exception = true

server = ARGV[0] || "irc.freenode.net"
port = ARGV[1] && ARGV[1].to_i || 6667
user = ARGV[2] || 'gobosox'
full_name = ARGV[3] || ARGV[2] || 'gobosox'
password = ARGV[4] || ''

@games = {}
@last_message = {}

def unset_game(channel)
  Thread.exclusive { @games.delete(channel) }
end

def set_game(channel, game)
  Thread.exclusive { @games[channel] = game }
end

def game(channel)
  Thread.exclusive { @games[channel] }
end

def handle_command(irc, channel, command, arguments = String.new)
  case command
  when '!game'
    team, date = arguments.split(/\s+/)[0, 2]
    if date
      t = Time.parse(date)
      date = Date.new(t.year, t.month, t.day)
    else
      date = Date.today
    end
    games = MLBAPI::Base.find_all_games_by_team(team, date)
    if games.size == 0
      irc.privmsg channel, "There's no games by that team. Please use the 2- or 3-letter team code."
    elsif games.size == 1
      set_game(channel, games.first)
      announce_game(irc, channel)
    else
      game = games.detect { |g| g.ind == 'I' }
      if game
        set_game(channel, games.first)
        announce_game(irc, channel)
      else
        irc.privmsg channel, "No games by that team are currently underway."
      end
    end
  when '!stfu'
    unset_game(channel)
    irc.privmsg channel, "That makes me a sad panda."
  when '!pitch'
    game = game(channel)
    if game
      if game.at_bat && (pitch = game.at_bat.pitches.last)
        irc.privmsg channel, "[#{game.away_name_abbrev} @ #{game.home_name_abbrev}] Last pitch: #{pitch.start_speed.to_i} MPH #{pitch.pitch_type_desc} @ #{pitch.x.to_i}, #{pitch.y.to_i}"
      else
        irc.privmsg channel, "Sorry, no pitch data for this at-bat yet."
      end
    else
      irc.privmsg channel, "You must select a game first."
    end
  end
end

def announce_game(irc, channel)
  game = game(channel)
  irc.privmsg channel, "Game selected: #{game.away_team_runs} #{game.away_name_abbrev} @ #{game.home_name_abbrev} #{game.home_team_runs}, #{game.top_or_bot} #{game.inning}, #{game.outs} outs"
end

def check_games(irc)
   @games.keys.each do |ch|
    game = game(ch)
    next unless game
    begin
      game.update
      msg = game.at_bat && game.at_bat.des.to_s.strip
      if @last_message[ch] != msg
        unless msg.nil? || msg.empty?
          pitch = game.at_bat.pitches.last
          to_send = "[#{game.away_name_abbrev} @ #{game.home_name_abbrev}] "
          if pitch && pitch.start_speed.to_i > 0
            to_send += "[#{pitch.start_speed.to_i}mph #{pitch.pitch_type} @ #{pitch.x.to_i},#{pitch.y.to_i}] "
          end
          to_send += msg.gsub(/  +/, ' ')
          to_send += game.outs.to_i == 1 ? " 1 out." : " #{game.outs} outs."
          if game.at_bat.rbi?
            to_send += " #{game.home_team_name} #{game.home_team_runs}, #{game.away_team_name} #{game.away_team_runs}."
          end
          irc.privmsg ch, to_send
        end
        @last_message[ch] = msg
      end
    rescue MLBAPI::FetchError
    end
  end
end

Net::IRC.start user, password, full_name, server, port do |irc|

  # thread to respond to messages.
  Thread.new do
    irc.each do |message|
      case message
      # TODO: required = VERSION, PING, CLIENTINFO, ACTION
      # TODO: handle internally... probably true for most CTCP requests
      when Net::IRC::CTCPVersion
        irc.ctcp_version(message.source, "net-irc simple-client", Net::IRC::VERSION, PLATFORM, "http://www.github.com/sbfaulkner/net-irc")

      when Net::IRC::CTCPAction
        puts "#{highlight(message.source, BOLD, fg(YELLOW))} #{highlight(message.target, BOLD, fg(GREEN))}: #{highlight(message.text, BOLD)}"

      when Net::IRC::CTCPPing
        irc.ctcp_ping(message.source, message.arg)

      when Net::IRC::CTCPTime
        irc.ctcp_time(message.source)

      when Net::IRC::CTCP
        puts highlight("Unhandled CTCP REQUEST: #{message.class} (#{message.keyword})", BOLD, fg(RED))

      when Net::IRC::Join
        puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} joined #{highlight(message.channels.first, BOLD, fg(GREEN))}."

      when Net::IRC::Part
        if message.text && ! message.text.empty?
          puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} has left #{highlight(message.channels.first, BOLD, fg(GREEN))} (#{message.text})."
        else
          puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} has left #{highlight(message.channels.first, BOLD, fg(GREEN))}."
        end

      when Net::IRC::Mode
        # TODO: handle internally
        puts highlight("#{message.channel} mode changed #{message.modes}", fg(BLUE))

      when Net::IRC::Quit
        if message.text && ! message.text.empty?
          puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} has quit (#{message.text})."
        else
          puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} has quit."
        end

      when Net::IRC::Notice
        puts highlight(message.text, fg(CYAN))

      when Net::IRC::Privmsg
        puts "#{highlight(message.prefix.nickname, BOLD, fg(YELLOW))} #{highlight(message.target, BOLD, fg(GREEN))}: #{highlight(message.text, BOLD)}"
        if message.target[0] == ?# && message.text[0] == ?!
          handle_command(irc, message.target, *message.text.split(/\s+/, 2))
        end

      when Net::IRC::Nick
        puts "#{highlight(message.prefix.nickname, BOLD)} is now #{highlight(message.nickname, BOLD, fg(YELLOW))}"

      when Net::IRC::ErrNicknameinuse
        irc.nick message.nickname.sub(/\d*$/) { |n| n.to_i + 1 }

      when Net::IRC::ErrNeedreggednick
        irc.privmsg('nickserv', 'help')

      when Net::IRC::RplLoggedin, Net::IRC::RplLoggedout
        puts highlight(message.text, fg(GREEN))

      when Net::IRC::Error
        puts highlight("Unhandled ERROR: #{message.class} (#{message.command})", BOLD, fg(RED))

      when Net::IRC::RplWelcome, Net::IRC::RplYourhost, Net::IRC::RplCreated
        puts message.text

      when Net::IRC::RplLuserclient, Net::IRC::RplLuserme, Net::IRC::RplLocalusers, Net::IRC::RplGlobalusers, Net::IRC::RplStatsconn
        puts highlight(message.text, fg(BLUE))

      when Net::IRC::RplLuserop, Net::IRC::RplLuserchannels
        puts highlight("#{message.count} #{message.text}", fg(BLUE))

      when Net::IRC::RplIsupport
        # TODO: handle internally... parse into capabilities collection

      when Net::IRC::RplMyinfo
      when Net::IRC::RplMotdstart

      when Net::IRC::RplTopic
        # TODO: handle internally
        puts "#{highlight(message.channel, BOLD, fg(GREEN))}: #{message.text}"

      when Net::IRC::RplTopicwhotime
        # TODO: handle internally
        puts "#{highlight(message.channel, BOLD, fg(GREEN))}: #{message.nickname} #{message.time.strftime("%Y/%m/%d %H:%M:%S")}"

      when Net::IRC::RplNamreply
        # TODO: handle internally
        puts "#{highlight(message.channel, BOLD, fg(GREEN))}: #{message.names.join(', ')}"

      when Net::IRC::RplEndofnames
        # TODO: handle internally

      when Net::IRC::RplMotd
        puts message.text.sub(/^- /,'')

      when Net::IRC::RplEndofmotd
        puts ""

      when Net::IRC::Reply
        puts highlight("Unhandled REPLY: #{message.class} (#{message.command})", BOLD, fg(RED))

      when Net::IRC::Message
        puts highlight("Unhandled MESSAGE: #{message.class} (#{message.command})", BOLD, fg(RED))

      else
        raise IOError, "unknown class #{message.class}"

      end
    end
  end

  Thread.new do
    loop do
      check_games(irc)
      sleep(5)
    end
  end

  while line = STDIN.readline
    scanner = StringScanner.new(line.chomp)
    if command = scanner.scan(/\/(\S+)\s*/) && scanner[1]
      case command.upcase
      when 'JOIN'
        # TODO: validate arguments... support for password... etc.
        irc.join scanner.rest

      when 'MSG'
        # TODO: validate arguments... support for password... etc.
        scanner.scan(/(\S+)\s+(.*)/)
        irc.privmsg(scanner[1], scanner[2])
      when 'PART'
        # TODO: validate arguments... support for password... etc.
        irc.part scanner.rest

      when 'QUIT'
        break
      else
        puts highlight("Unknown COMMAND: #{command}", BOLD, fg(RED))
      end
    elsif scanner.scan(/(\S+)\s+(.*)/)
      irc.privmsg(scanner[1], scanner[2])
    else
      # TODO: error? need a concept of a current room
    end
  end
end
