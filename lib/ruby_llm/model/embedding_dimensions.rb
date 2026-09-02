# frozen_string_literal: true

module RubyLLM
  module Model
    # The output dimensionality of an embedding model.
    #
    # This is deliberately a field of its own rather than a reading of
    # max_output_tokens. models.dev records an embedding model's vector width
    # in +limit.output+, which RubyLLM maps to +max_output_tokens+ - a field
    # that means "how many tokens this model may generate". The two are
    # different facts about a model and they disagree: models.dev states
    # +limit.output+ of 1 for gemini-embedding-001, whose vectors are 3072
    # wide. A consumer that reads the token limit as a vector width gets the
    # wrong number, so the vector width is recorded here and nowhere else.
    #
    # A fixed-width model carries only a default. A model that accepts an
    # output-dimension parameter (Matryoshka truncation, as in
    # gemini-embedding-001, text-embedding-3-* and titan-embed-text-v2) is
    # +configurable?+, and says as much as its provider documents: a discrete
    # list of +supported+ sizes, a continuous +min+/+max+ range, or both.
    # Nothing is inferred that the provider does not state.
    class EmbeddingDimensions
      attr_reader :default, :supported, :min, :max

      # Builds dimensions from whatever the registry, a provider or a JSON
      # round-trip hands over. Returns nil for a model that has none, so
      # "not an embedding model" and "an embedding model of unknown width"
      # both read as nil rather than as a fabricated zero.
      def self.from(value)
        return nil if value.nil?
        return value if value.is_a?(self)
        return new(default: value) if value.is_a?(Integer)

        data = normalize(value)
        return nil if data.nil? || data.empty?

        dimensions = new(data)
        dimensions.default.nil? && dimensions.supported.empty? ? nil : dimensions
      end

      # Asks a provider's capabilities module for a model's width, when it has
      # one to give.
      #
      # Several providers reuse another's model parser (DeepSeek, xAI and
      # Perplexity all borrow OpenAI's), so the capabilities object handed to a
      # parser is not always one that knows about embedding widths. A provider
      # with nothing to say answers nothing, rather than blowing up the listing.
      def self.from_capabilities(capabilities, model_id)
        return nil unless capabilities.respond_to?(:embedding_dimensions_for)

        capabilities.embedding_dimensions_for(model_id)
      end

      def self.normalize(value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)
        return value.to_h.transform_keys(&:to_sym) if value.respond_to?(:to_h)

        nil
      rescue TypeError
        nil
      end
      private_class_method :normalize

      def initialize(data = {})
        data = self.class.send(:normalize, data) || {}
        @supported = Array(data[:supported]).filter_map { |value| positive_integer(value) }.uniq.sort
        @min = positive_integer(data[:min])
        @max = positive_integer(data[:max])
        @default = positive_integer(data[:default]) || @max || @supported.last
        @configurable = derive_configurable(data[:configurable])
        @supported = [@default] if @supported.empty? && !@configurable && @default
      end

      # True when the model accepts an output-dimension parameter.
      def configurable?
        @configurable
      end

      def fixed?
        !configurable?
      end

      # True when +size+ is a width this model can produce.
      #
      # A configurable model whose provider documents no bounds accepts any
      # positive size: saying "no" there would be an invention, not a fact.
      def supports?(size)
        size = positive_integer(size)
        return false if size.nil?
        return true if size == default || supported.include?(size)
        return false unless configurable?

        within_documented_bounds?(size)
      end

      def to_h
        hash = { default: default, configurable: configurable? }
        hash[:supported] = supported if supported.any? && supported != [default]
        hash[:min] = min if min
        hash[:max] = max if max
        hash
      end

      def ==(other)
        other.is_a?(self.class) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      def to_s
        return default.to_s unless configurable?

        "#{default} (configurable)"
      end

      private

      # A documented list with no documented range is the whole answer:
      # anything off it is not a size the provider says it will return.
      def within_documented_bounds?(size)
        return false if min && size < min
        return false if max && size > max

        supported.empty? || !min.nil? || !max.nil?
      end

      def derive_configurable(explicit)
        return explicit if [true, false].include?(explicit)
        return true if explicit.to_s == 'true'
        return false if explicit.to_s == 'false'

        @supported.size > 1 || (!@min.nil? && !@max.nil? && @min != @max)
      end

      def positive_integer(value)
        return nil if value.nil?
        return nil unless value.respond_to?(:to_i)

        integer = value.to_i
        integer.positive? ? integer : nil
      rescue StandardError
        nil
      end
    end
  end
end
