# frozen_string_literal: true

module RubyLLM
  module Model
    # Stores the pricing values for a single pricing tier.
    #
    # A price of 0.0 is a *known* price (the provider charges nothing) and is
    # kept, so consumers can tell "this is free" apart from "we do not know
    # what this costs". Only nil — the absence of information — is dropped.
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

      def initialize(data = {})
        @values = {}

        data.each do |key, value|
          @values[key.to_sym] = value unless value.nil?
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

      def [](key)
        @values[key.to_sym]
      end

      def to_h
        @values
      end
    end
  end
end
