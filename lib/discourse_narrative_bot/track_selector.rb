module DiscourseNarrativeBot
  class TrackSelector
    include Actions

    GENERIC_REPLIES_COUNT_PREFIX = 'discourse-narrative-bot:track-selector-count:'.freeze

    TRACKS = [
      NewUserNarrative,
      AdvancedUserNarrative
    ]

    RESET_TRIGGER = 'track'.freeze

    def initialize(input, user, post_id:, topic_id: nil)
      @input = input
      @user = user
      @post_id = post_id
      @topic_id = topic_id
      @post = Post.find_by(id: post_id)
    end

    def select
      data = Store.get(@user.id)

      if @post && @input != :delete
        topic_id = @post.topic_id
        bot_mentioned = bot_mentioned?(@post)

        TRACKS.each do |klass|
          if bot_mentioned && selected_track(klass)
            klass.new.reset_bot(@user, @post)
            return
          end
        end

        if (data && data[:topic_id] == topic_id)
          state = data[:state]
          klass = (data[:track] || NewUserNarrative.to_s).constantize

          if ((state && state.to_sym == :end) && @input == :reply)
            if bot_mentioned?(@post)
              mention_replies
            else
              generic_replies(klass::RESET_TRIGGER)
            end
          else
            previous_status = data[:attempted]
            current_status = klass.new.input(@input, @user, post: @post)
            data = Store.get(@user.id)
            data[:attempted] = !current_status

            if previous_status && data[:attempted] == previous_status
              generic_replies(klass::RESET_TRIGGER)
            else
              $redis.del(generic_replies_key(@user))
            end

            Store.set(@user.id, data)
          end

          return
        end

        if (@input == :reply) && (bot_mentioned?(@post) || pm_to_bot?(@post) || reply_to_bot_post?(@post))
          mention_replies
        end
      elsif data && data[:state]&.to_sym != :end && @input == :delete
        klass = (data[:track] || NewUserNarrative.to_s).constantize
        klass.new.input(@input, @user, post: @post, topic_id: @topic_id)
      end
    end

    private

    def selected_track(klass)
      return if klass.respond_to?(:can_start?) && !klass.can_start?(@user)
      @post.raw.match(/#{RESET_TRIGGER} #{klass::RESET_TRIGGER}/)
    end

    def mention_replies
      post_raw = @post.raw

      raw =
        if match_data = post_raw.match(/roll (\d+)d(\d+)/i)
          I18n.t(i18n_key('random_mention.dice'),
            results: Dice.new(match_data[1].to_i, match_data[2].to_i).roll.join(", ")
          )
        elsif match_data = post_raw.match(/quote/i)
          I18n.t(i18n_key('random_mention.quote'), QuoteGenerator.generate)
        else
          discobot_username = self.class.discobot_user.username
          data = Store.get(@user.id)

          tracks = [NewUserNarrative::RESET_TRIGGER]

          if data && (completed = data[:completed]) && completed.include?(NewUserNarrative.to_s)
            tracks << AdvancedUserNarrative::RESET_TRIGGER
          end

          message = I18n.t(
            i18n_key('random_mention.tracks'),
            discobot_username: discobot_username,
            reset_trigger: RESET_TRIGGER,
            default_track: NewUserNarrative::RESET_TRIGGER,
            tracks: tracks.join(', ')
          )

          message << "\n\n#{I18n.t(i18n_key('random_mention.bot_actions'), discobot_username: discobot_username)}"
        end

      fake_delay

      reply_to(@post, raw)
    end

    def generic_replies_key(user)
      "#{GENERIC_REPLIES_COUNT_PREFIX}#{user.id}"
    end

    def generic_replies(reset_trigger)
      key = generic_replies_key(@user)
      reset_trigger = "#{RESET_TRIGGER} #{reset_trigger}"
      count = ($redis.get(key) || $redis.setex(key, 900, 0)).to_i

      case count
      when 0
        reply_to(@post, I18n.t(i18n_key('do_not_understand.first_response'),
          reset_trigger: reset_trigger,
          discobot_username: self.class.discobot_user.username
        ))
      when 1
        reply_to(@post, I18n.t(i18n_key('do_not_understand.second_response'),
          reset_trigger: reset_trigger,
          discobot_username: self.class.discobot_user.username
        ))
      else
        # Stay out of the user's way
      end

      $redis.incr(key)
    end

    def i18n_key(key)
      "discourse_narrative_bot.track_selector.#{key}"
    end
  end
end
