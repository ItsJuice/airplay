module Airplay
  class Player
    PlaybackInfo = Struct.new(:info) do
      def uuid
        info["uuid"]
      end

      def duration
        info["duration"]
      end

      def empty?
        info.has_key?('error') and info['error'] == 'empty response'
      end

      def has_duration?
        !duration.to_f.zero?
      end

      def password_required?
        info['password_error'] == 'missing'
      end

      def password_wrong?
        info['password_error'] == 'wrong'
      end

      def position
        info["position"]
      end

      def percent
        return unless position && has_duration?
        (position * 100 / duration).floor
      end

      def likely_to_keep_up?
        info["playbackLikelyToKeepUp"]
      end

      def stall_count
        info["stallCount"]
      end

      def ready_to_play?
        info["readyToPlay"]
      end

      def stopped?
        info.empty?
      end

      def remaining_duration
        return 100.0 if duration.nil?
        return 100.0 if position.nil?
        duration - position
      end

      def playing?
        info.has_key?("rate") && info.fetch("rate", false) && !info["rate"].zero?
      end

      def paused?
        !playing?
      end

      def played?
        # This is weird. I know. Bear with me.
        info.keys.size == 2 || (paused? && remaining_duration < 1.0)
      end
    end
  end
end
