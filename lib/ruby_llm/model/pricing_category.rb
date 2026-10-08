# frozen_string_literal: true

module RubyLLM
  module Model
    # Represents pricing tiers for different usage categories (standard and batch)
    #
    # A tier is normally a single set of prices. When a provider has announced a
    # price that changes on a known date, the tier instead carries a
    # PricingSchedule and the reader methods resolve the price in effect now.
    # Use #at to resolve the price in effect at some other moment - which is what
    # a consumer needs when pricing a call it made in the past.
    #
    # A set of prices may also change with the size of the prompt (see
    # PricingTier). The readers then answer for a prompt of unknown size - the
    # base prices - unless given +prompt_tokens+; #for_prompt pins a size.
    class PricingCategory
      attr_reader :standard_schedule, :batch_schedule

      def initialize(data = {})
        @standard_schedule = build_slot(data[:standard])
        @batch_schedule = build_slot(data[:batch])
      end

      def standard(at: nil, prompt_tokens: nil)
        resolve(@standard_schedule, at)&.for_prompt(prompt_tokens)
      end

      def batch(at: nil, prompt_tokens: nil)
        resolve(@batch_schedule, at)&.for_prompt(prompt_tokens)
      end

      # This category as it stood at a given time.
      def at(time)
        Resolved.new(self, time:)
      end

      # This category for a prompt of a given size.
      def for_prompt(prompt_tokens)
        Resolved.new(self, prompt_tokens:)
      end

      def input(at: nil, prompt_tokens: nil)
        standard(at:, prompt_tokens:)&.input_per_million
      end

      def output(at: nil, prompt_tokens: nil)
        standard(at:, prompt_tokens:)&.output_per_million
      end

      def cache_read_input(at: nil, prompt_tokens: nil)
        tier = standard(at:, prompt_tokens:)
        tier&.cache_read_input_per_million || tier&.cached_input_per_million
      end

      def cache_write_input(at: nil, prompt_tokens: nil)
        tier = standard(at:, prompt_tokens:)
        tier&.cache_write_input_per_million || tier&.cache_creation_input_per_million
      end

      # The price of a write to the 1-hour cache, which Anthropic charges apart
      # from the 5-minute write (#cache_write_input). Unknown unless stated.
      def cache_write_1h_input(at: nil, prompt_tokens: nil)
        standard(at:, prompt_tokens:)&.cache_write_1h_input_per_million
      end

      def reasoning_output(at: nil, prompt_tokens: nil)
        standard(at:, prompt_tokens:)&.reasoning_output_per_million
      end

      alias cached_input cache_read_input
      alias cache_creation_input cache_write_input

      # True when this category's price changes on a known date.
      def scheduled?
        [@standard_schedule, @batch_schedule].any?(PricingSchedule)
      end

      def [](key)
        key == :batch ? batch : standard
      end

      def to_h
        result = {}
        result[:standard] = serialize(@standard_schedule) if @standard_schedule
        result[:batch] = serialize(@batch_schedule) if @batch_schedule
        result
      end

      # A PricingCategory pinned to a moment in time and to a prompt size, so the
      # ordinary readers answer for that moment and that size. Either may be
      # left open, and pinned later.
      class Resolved
        def initialize(category, time: nil, prompt_tokens: nil)
          @category = category
          @time = time
          @prompt_tokens = prompt_tokens
        end

        def at(time)
          Resolved.new(@category, time:, prompt_tokens: @prompt_tokens)
        end

        def for_prompt(prompt_tokens)
          Resolved.new(@category, time: @time, prompt_tokens:)
        end

        %i[standard batch input output cache_read_input cache_write_input cache_write_1h_input
           reasoning_output].each do |name|
          define_method(name) { @category.public_send(name, at: @time, prompt_tokens: @prompt_tokens) }
        end

        alias cached_input cache_read_input
        alias cache_creation_input cache_write_input
      end

      private

      def build_slot(tier_data)
        schedule = PricingSchedule.from(tier_data)
        return schedule if schedule&.any?
        return nil if empty_tier?(tier_data)

        PricingTier.new(tier_data || {})
      end

      def resolve(slot, time)
        return nil unless slot
        return slot.at(time || Time.now) if slot.is_a?(PricingSchedule)

        slot
      end

      def serialize(slot)
        slot.to_h
      end

      # A tier that carries only nils tells us nothing and is dropped. A tier
      # holding 0.0 is a real, known price and is kept.
      def empty_tier?(tier_data)
        return true unless tier_data

        tier_data.values.all?(&:nil?)
      end
    end
  end
end
