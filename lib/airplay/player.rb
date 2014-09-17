require "uri"
require "forwardable"
require "micromachine"
require "celluloid/autostart"
require "cfpropertylist"

require "airplay/connection"
require "airplay/server"
require "airplay/player/timers"
require "airplay/player/media"
require "airplay/player/playback_info"
require "airplay/player/playlist"

module Airplay
  # Public: The class that handles all the video playback
  #
  class Player
    extend Forwardable
    include Celluloid

    class PlayingInterrupted < Exception; end

    def_delegators :@machine, :state, :on

    attr_reader :device

    trap_exit :handle_error

    def initialize(device)
      @device = device
      @callbacks = []
    end

    # Public: Gets all the playlists
    #
    # Returns the Playlists
    #
    def playlists
      @_playlists ||= Hash.new { |h,k| h[k] = Playlist.new(k) }
    end

    # Public: Gets the current playlist
    #
    # Returns the first Playlist if none defined or creates a new one
    #
    def playlist
      @_playlist ||= if playlists.any?
                       key, value = playlists.first
                       value
                     else
                       Playlist.new("Default")
                     end
    end

    # Public: Sets a given playlist
    #
    # name - The name of the playlist to be used
    #
    # Returns nothing
    #
    def use(name)
      @_playlist = playlists[name]
    end

    # Public: Plays a given url or file.
    #         Creates a new persistent connection to ensure that
    #         the socket will be kept alive
    #
    # file_or_url - The url or file to be reproduced
    # options - Optional starting time
    #
    # Returns nothing
    #
    def play(media_to_play = "playlist", options = {})
      start_the_machine
      check_for_playback_status

      media = case true
              when media_to_play.is_a?(Media) then media_to_play
              when media_to_play == "playlist" && playlist.any?
                playlist.next
              else Media.new(media_to_play)
              end

      content = {
        "Content-Location" => media,
        "Start-Position" => options.fetch(:time, 0.0)
      }

      data = content.map { |k, v| "#{k}: #{v}" }.join("\r\n")

      response = persistent.async.post("/play", data + "\r\n", {
        "Content-Type" => "text/parameters"
      })

      timers.reset
    end

    # Public: Handles the progress of the playback, the given &block get's
    #         executed every second while the video is played.
    #
    # &block - Block to be executed in every playable second.
    #
    # Returns nothing
    #
    def progress(callback)
      @callbacks << callback
    end

    def callbacks_empty?
      @callbacks.empty?
    end

    # Public: Plays the next video in the playlist
    #
    # Returns the video that was selected or nil if none
    #
    def next
      video = playlist.next
      play(video) if video
      video
    end

    # Public: Plays the previous video in the playlist
    #
    # Returns the video that was selected or nil if none
    #
    def previous
      video = playlist.previous
      play(video) if video
      video
    end

    # Public: Shows the current playback time if a video is being played.
    #
    # Returns a hash with the :duration and current :position
    #
    def scrub
      return unless playing?
      response = connection.get("/scrub").response
      parts = response.body.split("\n")
      Hash[parts.collect { |v| v.split(": ") }]
    end

    # Public: checks current playback information
    #
    # Returns a PlaybackInfo object with the playback information
    #
    def info
      answer = nil
      retries = 10
      while answer.nil? and retries > 0
        answer = connection.get("/playback-info")
        retries -= 1
      end

      if answer.nil?
        hash = {'error' => 'socket error'}
      elsif answer.kind_of?(Airplay::Connection::PasswordRequired)
        hash = {'password_error' => 'missing'}
      elsif answer.kind_of?(Airplay::Connection::WrongPassword)
        hash = {'password_error' => 'wrong'}
      else
        response = answer.response
        plist = CFPropertyList::List.new(data: response.body)
        hash = CFPropertyList.native_types(plist.value)
      end
      PlaybackInfo.new(hash)
    end

    # Public: Resumes a paused video
    #
    # Returns nothing
    #
    def resume
      connection.async.post("/rate?value=1")
    end

    # Public: Pauses a playing video
    #
    # Returns nothing
    #
    def pause
      connection.async.post("/rate?value=0")
    end

    # Public: Stops the video
    #
    # Returns nothing
    #
    def stop
      connection.async.post("/stop")
    end

    # Public: Seeks to the specified position (seconds) in the video
    #
    # Returns nothing
    #
    def seek(position)
      connection.async.post("/scrub?position=#{position}")
    end

    def loading?; state == :loading end
    def playing?; state == :playing end
    def paused?;  state == :paused  end
    def played?;  state == :played  end
    def stopped?; state == :stopped end

    # Public: Locks the execution until the video gets fully played
    #
    # Returns nothing
    #
    def wait
      sleep 1 while wait_for_playback?
      cleanup
    end

    # Public: Cleans up the player
    #
    # Returns nothing
    #
    def cleanup
      timers.cancel
      persistent.close
      persistent.cleanup
      persistent.terminate
      @_persistent = nil

      unless @_connection.nil?
        connection.close
        connection.cleanup
        connection.terminate
      end
    end

    private

    # Private: Returns if we have to wait for playback
    #
    # Returns a boolean if we need to wait
    #
    def wait_for_playback?
      return true if playlist.next?
      loading? || playing? || paused?
    end

    # Private: The timers
    #
    # Returns a Timers object
    #
    def timers
      @_timers ||= Timers.new
    end

    # Private: The connection
    #
    # Returns the current connection to the device
    #
    def connection
      @_connection ||= Airplay::Connection.new(@device).tap do |connection|
        link connection
      end
    end

    # Private: The persistent connection
    #
    # Returns the persistent connection to the device
    #
    def persistent
      @_persistent ||= open_persistent
    end

    def open_persistent
      Airplay::Connection.new(@device, keep_alive: true).tap do |connection|
        #link connection.socket
      end
    end

    # Private: Starts checking for playback status ever 1 second
    #          Adds one timer to the pool
    #
    # Returns nothing
    #
    def check_for_playback_status
      return unless timers.empty?
      timers << every(1) do
        current_info = info

        case true
        when current_info.stopped? && playing?  then @machine.trigger(:stopped)
        when current_info.played?  && playing?  then @machine.trigger(:played)
        when current_info.playing? && !playing? then @machine.trigger(:playing)
        when current_info.paused?  && playing?  then @machine.trigger(:paused)
        end

        previously_playing = @previous || playing?
        if playing? or previously_playing
          @callbacks.each do |callback|
            callback.call(current_info)
          end
        end
        @previous = playing?
      end
    end

    def handle_error actor, event
      puts "Exception = #{ event.inspect }"
      if actor.kind_of?(Airplay::Connection)
        raise PlayingInterrupted
        ## throw error on up the line
        #puts "Handling reconnection!"
        ## reopen connection
        #@_persistent = nil
        #persistent
      end
    end

    # Private: Get ready the state machine
    #
    # Returns nothing
    #
    def start_the_machine
      @machine = MicroMachine.new(:loading)

      @machine.on(:stopped) { cleanup }
      @machine.on(:played)  do
        cleanup
        self.next if playlist.next?
      end

      @machine.when(:loading, :stopped => :loading)
      @machine.when(:playing, {
        :paused  => :playing,
        :loading => :playing,
        :stopped => :playing
      })

      @machine.when(:paused,  :loading => :paused,  :playing => :paused)
      @machine.when(:stopped, :playing => :stopped, :paused  => :stopped)
      @machine.when(:played,  :playing => :played,  :paused  => :played)
    end
  end
end
