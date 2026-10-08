# frozen_string_literal: true

module RubyLLM
  # Represents token usage for a response.
  class Tokens
    attr_reader :input, :output, :cached, :cache_creation, :thinking

    # rubocop:disable-next Metrics/ParameterLists
    def initialize(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
      @input = input
      @output = output
      @cached = cached
      @cache_creation = cache_creation
      @thinking = thinking || reasoning
    end

    # rubocop:disable-next Metrics/ParameterLists
    def self.build(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
      return nil if [input, output, cached, cache_creation, thinking, reasoning].all?(&:nil?)

      new(
        input: input,
        output: output,
        cached: cached,
        cache_creation: cache_creation,
        thinking: thinking,
        reasoning: reasoning
      )
    end

    def to_h
      {
        input_tokens: input,
        output_tokens: output,
        cached_tokens: cached,
        cache_creation_tokens: cache_creation,
        thinking_tokens: thinking
      }.compact
    end

    def reasoning
      thinking
    end

    # The size of the whole prompt the provider processed: the standard input
    # plus what was read from and written to the cache. Every provider counts a
    # prompt this way when its price depends on the prompt's size - Anthropic's
    # total input tokens, Gemini's promptTokenCount, OpenAI's input tokens -,
    # and `input` never repeats the cache buckets, so their sum is that size.
    # nil when the provider reported none of them.
    def prompt
      buckets = [input, cache_read, cache_write]
      return nil if buckets.all?(&:nil?)

      buckets.sum(&:to_i)
    end

    def cache_read
      cached
    end

    def cache_write
      cache_creation
    end
  end
end
