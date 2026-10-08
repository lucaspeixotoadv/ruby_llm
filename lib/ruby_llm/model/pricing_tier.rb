# frozen_string_literal: true

module RubyLLM
  module Model
    # Stores the pricing values for a single pricing tier.
    #
    # A price of 0.0 is a *known* price (the provider charges nothing) and is
    # kept, so consumers can tell "this is free" apart from "we do not know
    # what this costs". Only nil — the absence of information — is dropped.
    #
    # Some models charge more once the prompt grows past a size: Claude Haiku
    # 5.5 above 100,000 tokens, the Gemini Pro models above 200,000. Such a tier
    # carries +prompt_tiers+, each stating the prompt size it starts above
    # (+above_prompt_tokens+, exclusive) and the prices that apply to the whole
    # call from there on. #for_prompt answers with the prices for a given prompt
    # size. A prompt tier does not inherit from the one below it: a price it
    # leaves out is unknown at that size, not the cheaper one.
    class PricingTier
      ATTRIBUTES = %i[
        input_per_million
        output_per_million
        cache_read_input_per_million
        cache_write_input_per_million
        cached_input_per_million
        cache_creation_input_per_million
        reasoning_output_per_million
      ].freeze

      PROMPT_TIERS = :prompt_tiers
      PROMPT_THRESHOLD = :above_prompt_tokens

      # The prompt size this tier's prices start above, when it is a prompt tier.
      attr_reader :above_prompt_tokens

      def initialize(data = {})
        @values = {}
        @prompt_tiers = []

        data.each do |key, value|
          case key.to_sym
          when PROMPT_TIERS then @prompt_tiers = build_prompt_tiers(value)
          when PROMPT_THRESHOLD then @above_prompt_tokens = value&.to_i
          else @values[key.to_sym] = value unless value.nil?
          end
        end
      end

      ATTRIBUTES.each do |attribute|
        define_method(attribute) do
          @values[attribute]
        end

        define_method("#{attribute}=") do |value|
          @values[attribute] = value unless value.nil?
        end
      end

      # The prices for a prompt of +prompt_tokens+ tokens: those of the highest
      # prompt tier the prompt goes past, or these when it goes past none. An
      # unknown prompt size answers with these.
      def for_prompt(prompt_tokens)
        return self if prompt_tokens.nil?

        @prompt_tiers.select { |tier| prompt_tokens.to_i > tier.above_prompt_tokens }
                     .max_by(&:above_prompt_tokens) || self
      end

      def prompt_tiers?
        @prompt_tiers.any?
      end

      def [](key)
        @values[key.to_sym]
      end

      def to_h
        result = @above_prompt_tokens ? { PROMPT_THRESHOLD => @above_prompt_tokens }.merge(@values) : @values.dup
        result[PROMPT_TIERS] = @prompt_tiers.map(&:to_h) if prompt_tiers?
        result
      end

      private

      # A prompt tier without a threshold, or without a single price, says
      # nothing and is dropped.
      def build_prompt_tiers(raw_tiers)
        Array(raw_tiers).filter_map do |raw|
          next unless raw.is_a?(Hash)

          tier = PricingTier.new(raw.reject { |key, _| key.to_sym == PROMPT_TIERS })
          tier if tier.above_prompt_tokens && tier.to_h.except(PROMPT_THRESHOLD).any?
        end
      end
    end
  end
end
