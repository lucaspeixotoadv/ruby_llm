# frozen_string_literal: true

module RubyLLM
  module Model
    # An ordered list of dated PricingTiers for a single pricing tier slot.
    #
    # Providers sometimes announce a price that changes on a known future date
    # (an introductory price that expires, a scheduled increase). Recording only
    # today's number guarantees the registry becomes wrong the moment the date
    # passes, and recording only tomorrow's number is wrong until then. A
    # schedule records every announced price with the window it applies to, and
    # resolves the one in effect at a given time.
    #
    # Each entry may carry +effective_from+ (inclusive) and +effective_until+
    # (exclusive). An entry with neither is the open-ended default, used when no
    # dated entry matches.
    class PricingSchedule
      ENTRY_BOUNDS = %i[effective_from effective_until].freeze
      EPOCH = Time.at(0).utc.freeze

      attr_reader :entries

      # Builds a schedule from tier data, or nil when the data holds no
      # schedule. Tier data without a :schedule key is an ordinary single-price
      # tier and is left to PricingTier.
      def self.from(data)
        return nil unless data.is_a?(Hash)

        raw = data[:schedule] || data['schedule']
        return nil unless raw.is_a?(Array) && raw.any?

        new(raw)
      end

      def initialize(raw_entries)
        @entries = Array(raw_entries).filter_map { |entry| build_entry(entry) }
      end

      def any?
        @entries.any?
      end

      # The PricingTier in effect at +time+, or nil when nothing applies.
      #
      # Dated entries win over the open-ended default, and the most recently
      # started matching entry wins over an older one.
      def at(time = Time.now)
        moment = parse_time(time) || Time.now
        chosen = @entries.select { |entry| covers?(entry, moment) }
                         .max_by { |entry| entry[:from] || EPOCH }
        chosen ||= @entries.find { |entry| undated?(entry) }
        chosen && chosen[:tier]
      end

      def to_h
        { schedule: @entries.map { |entry| serialize_entry(entry) } }
      end

      private

      def build_entry(entry)
        return nil unless entry.is_a?(Hash)

        normalized = entry.to_h.transform_keys(&:to_sym)
        prices = normalized.except(*ENTRY_BOUNDS)
        tier = PricingTier.new(prices)
        return nil if tier.to_h.empty?

        {
          from: parse_time(normalized[:effective_from]),
          until: parse_time(normalized[:effective_until]),
          tier: tier
        }
      end

      # Bare dates are read as UTC midnight so a registry entry means the same
      # thing wherever it is loaded.
      def parse_time(value)
        return nil if value.nil?
        return value.utc if value.is_a?(Time)

        text = value.to_s
        text = "#{text}T00:00:00Z" if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Utils.to_time(text)&.utc
      rescue ArgumentError
        nil
      end

      def undated?(entry)
        entry[:from].nil? && entry[:until].nil?
      end

      def covers?(entry, time)
        return false if undated?(entry)
        return false if entry[:from] && time < entry[:from]

        entry[:until].nil? || time < entry[:until]
      end

      def serialize_entry(entry)
        serialized = {}
        serialized[:effective_from] = entry[:from].utc.iso8601 if entry[:from]
        serialized[:effective_until] = entry[:until].utc.iso8601 if entry[:until]
        serialized.merge(entry[:tier].to_h)
      end
    end
  end
end
