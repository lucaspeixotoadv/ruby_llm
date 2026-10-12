# frozen_string_literal: true

module RubyLLM
  # A piece of a streamed message.
  #
  # A restart chunk carries no content: it tells the caller that the stream
  # started over -- the request failed after it had begun and was retried -- and
  # that the chunks it received before belong to an attempt that no longer
  # counts. The chunks that follow are the new attempt's.
  class Chunk < Message
    def self.restart
      new(role: :assistant, content: nil, restart: true)
    end

    def initialize(options = {})
      super
      @restart = options.fetch(:restart, false)
    end

    def restart?
      @restart
    end
  end
end
