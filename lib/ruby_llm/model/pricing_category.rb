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
    class PricingCategory
      attr_reader :standard_schedule, :batch_schedule

      def initialize(data = {})
        @standard_schedule = build_slot(data[:standard])
        @batch_schedule = build_slot(data[:batch])
      end

      def standard(at: nil)
        resolve(@standard_schedule, at)
      end

      def batch(at: nil)
        resolve(@batch_schedule, at)
      end

      # This category as it stood at a given time.
      def at(time)
        Resolved.new(self, time)
      end

      def input(at: nil)
        standard(at:)&.input_per_million
      end

      def output(at: nil)
        standard(at:)&.output_per_million
      end

      def cache_read_input(at: nil)
        tier = standard(at:)
        tier&.cache_read_input_per_million || tier&.cached_input_per_million
      end

      def cache_write_input(at: nil)
        tier = standard(at:)
        tier&.cache_write_input_per_million || tier&.cache_creation_input_per_million
      end

      def reasoning_output(at: nil)
        standard(at:)&.reasoning_output_per_million
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

      # A PricingCategory pinned to a moment in time, so the ordinary readers
      # answer for that moment.
      class Resolved
        def initialize(category, time)
          @category = category
          @time = time
        end

        %i[standard batch input output cache_read_input cache_write_input reasoning_output].each do |name|
          define_method(name) { @category.public_send(name, at: @time) }
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
