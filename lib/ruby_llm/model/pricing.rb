# frozen_string_literal: true

module RubyLLM
  module Model
    # A collection that manages and provides access to different categories of pricing information
    class Pricing
      CATEGORIES = %i[text_tokens images audio_tokens embeddings].freeze

      def initialize(data)
        @data = {}

        CATEGORIES.each do |category|
          @data[category] = PricingCategory.new(data[category]) if data[category] && !empty_pricing?(data[category])
        end
      end

      def text_tokens
        category(:text_tokens)
      end

      def images
        category(:images)
      end

      def audio_tokens
        category(:audio_tokens)
      end

      def embeddings
        category(:embeddings)
      end

      # This pricing as it stood at a given time. Categories whose price never
      # changed answer the same as they do now.
      def at(time)
        Resolved.new(self, time)
      end

      # True when any category's price changes on a known date.
      def scheduled?
        @data.each_value.any?(&:scheduled?)
      end

      def to_h
        @data.transform_values(&:to_h)
      end

      # Pricing pinned to a moment in time.
      class Resolved
        def initialize(pricing, time)
          @pricing = pricing
          @time = time
        end

        CATEGORIES.each do |category|
          define_method(category) { @pricing.public_send(category).at(@time) }
        end
      end

      private

      def category(name)
        @data[name] || PricingCategory.new
      end

      # Pricing is only "empty" when every tier value is nil. A category that
      # prices something at 0.0 is stating a known price and is kept, and a
      # category carrying a dated schedule is never empty.
      def empty_pricing?(data)
        return true unless data

        %i[standard batch].each do |tier|
          tier_data = data[tier]
          next unless tier_data

          return false if PricingSchedule.from(tier_data)&.any?

          tier_data.each_value do |value|
            return false unless value.nil?
          end
        end

        true
      end
    end
  end
end
