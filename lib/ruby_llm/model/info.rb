# frozen_string_literal: true

module RubyLLM
  module Model
    # Information about an AI model's capabilities, pricing, and metadata.
    class Info
      attr_reader :id, :name, :provider, :family, :created_at, :context_window, :max_output_tokens, :knowledge_cutoff,
                  :modalities, :capabilities, :pricing, :metadata, :reasoning_options, :embedding_dimensions

      # Create a default model with assumed capabilities
      def self.default(model_id, provider)
        new(
          id: model_id,
          name: model_id.tr('-', ' ').capitalize,
          provider: provider,
          capabilities: %w[function_calling streaming vision structured_output],
          modalities: { input: %w[text image], output: %w[text] },
          metadata: { warning: 'Assuming model exists, capabilities may not be accurate' }
        )
      end

      def initialize(data)
        @id = data[:id]
        @name = data[:name]
        @provider = data[:provider]
        @family = data[:family]
        @created_at = Utils.to_time(data[:created_at])&.utc
        @context_window = data[:context_window]
        @max_output_tokens = data[:max_output_tokens]
        @embedding_dimensions = EmbeddingDimensions.from(data[:embedding_dimensions])
        @knowledge_cutoff = Utils.to_date(data[:knowledge_cutoff])
        @modalities = Modalities.new(data[:modalities] || {})
        @capabilities = data[:capabilities] || []
        @pricing = Pricing.new(data[:pricing] || {})
        @metadata = data[:metadata]&.dup || {}
        @reasoning_options = normalize_reasoning_options(reasoning_options_from(data))
        store_reasoning_options_metadata
      end

      def supports?(capability)
        capabilities.include?(capability.to_s)
      end

      %w[function_calling structured_output batch reasoning citations streaming].each do |cap|
        define_method "#{cap}?" do
          supports?(cap)
        end
      end

      def display_name
        name
      end

      def label
        provider_name = provider_class&.name || provider
        "#{provider_name} - #{display_name}"
      end

      def max_tokens
        max_output_tokens
      end

      def supports_vision?
        modalities.input.include?('image')
      end

      # Width of the vectors this model returns, or nil when the model does not
      # embed or its width is not known.
      #
      # Never read max_output_tokens for this: that field is a token limit, and
      # for an embedding model models.dev fills it with whatever it put in
      # limit.output - 1 for gemini-embedding-001, 3072 for
      # text-embedding-3-large. Only one of those happens to be a vector width,
      # and neither is one by definition.
      def default_embedding_dimensions
        embedding_dimensions&.default
      end

      # True when the model accepts an output-dimension parameter.
      def configurable_embedding_dimensions?
        embedding_dimensions&.configurable? || false
      end

      def supports_embedding_dimensions?(size)
        embedding_dimensions&.supports?(size) || false
      end

      # Lifecycle status as stated by the registry (models.dev), e.g.
      # "deprecated" or "alpha". nil when the source states none - which means
      # "the source says nothing", not "the model is fine". RubyLLM neither
      # invents this value nor overrides it.
      def status
        value = metadata[:status] || metadata['status']
        value&.to_s
      end

      def deprecated?
        status == 'deprecated'
      end

      # What the registry states about a custom temperature, in three states:
      #
      #   true  - the model takes a temperature
      #   false - the model refuses one, so the parameter must be left out
      #   nil   - the source says nothing
      #
      # The third is not the second. models.dev describes the models it knows;
      # entries that reach the registry from a provider listing alone (dated
      # snapshots, preview ids) carry no temperature field at all, and reading
      # that silence as a refusal would drop a parameter the model accepts.
      # Callers that must act on a refusal ask #rejects_temperature?.
      #
      # rubocop:disable-next Style/ReturnNilInPredicateMethodDefinition
      def supports_temperature?
        value = metadata.key?(:temperature) ? metadata[:temperature] : metadata['temperature']
        return nil if value.nil?

        value ? true : false
      end

      # True only where the registry states the model refuses a custom
      # temperature. Unknown stays false here: nothing is dropped on a guess.
      def rejects_temperature?
        supports_temperature? == false
      end

      # True when the registry lists reasoning among the model's capabilities.
      #
      # Independent of #reasoning_options: models.dev states that a model
      # reasons far more often than it enumerates how the reasoning is steered,
      # and OpenAI's reasoning models carry no reasoning_options at all.
      def supports_reasoning?
        reasoning?
      end

      def reasoning_option(type)
        reasoning_options.find { |option| option[:type] == type.to_s }
      end

      def reasoning_option_values(type)
        Array(reasoning_option(type)&.fetch(:values, nil))
      end

      # The reasoning efforts the registry enumerates, or [] when it enumerates
      # none. Empty is "not stated" - see #supports_reasoning_effort?.
      def reasoning_efforts
        reasoning_option_values('effort')
      end

      # Whether the model takes a reasoning effort, and optionally whether it
      # takes a particular one. Three states, for the same reason as
      # #supports_temperature?:
      #
      #   nil   - the registry enumerates no reasoning options for this model,
      #           so it states nothing about efforts. Absent options are not an
      #           absent feature.
      #   false - the registry enumerates options and effort is not among them,
      #           or the effort asked for is outside the enumerated values.
      #   true  - effort is among them.
      # rubocop:disable-next Style/ReturnNilInPredicateMethodDefinition
      def supports_reasoning_effort?(effort = nil)
        return nil if reasoning_options.empty?

        option = reasoning_option('effort')
        return false unless option
        return true if effort.nil?

        values = Array(option[:values]).map(&:to_s)
        return nil if values.empty?

        values.include?(effort.to_s)
      end

      # Whether the model takes a thinking token budget, and optionally whether
      # a given budget is within the range the registry states. Same three
      # states as #supports_reasoning_effort?.
      # rubocop:disable-next Style/ReturnNilInPredicateMethodDefinition
      def supports_reasoning_budget?(budget = nil)
        return nil if reasoning_options.empty?

        option = reasoning_option('budget_tokens')
        return false unless option
        return true if budget.nil?

        within_reasoning_budget?(budget)
      end

      # Smallest thinking budget the registry states for this model, or nil when
      # it states none.
      def minimum_reasoning_budget
        reasoning_option('budget_tokens')&.[](:min)
      end

      # Largest thinking budget the registry states, or nil when it states none.
      # nil is "unbounded as far as the registry knows", not zero.
      def maximum_reasoning_budget
        reasoning_option('budget_tokens')&.[](:max)
      end

      def supports_video?
        modalities.input.include?('video')
      end

      def supports_functions?
        function_calling?
      end

      def input_price_per_million
        pricing.text_tokens.input
      end

      def output_price_per_million
        pricing.text_tokens.output
      end

      def cache_read_input_price_per_million
        pricing.text_tokens.cache_read_input
      end

      def cache_write_input_price_per_million
        pricing.text_tokens.cache_write_input
      end

      alias cached_input_price_per_million cache_read_input_price_per_million
      alias cache_creation_input_price_per_million cache_write_input_price_per_million

      def cost_for(tokens)
        tokens = tokens.tokens if tokens.respond_to?(:tokens)

        Cost.new(tokens:, model: self)
      end

      def provider_class
        RubyLLM::Provider.resolve provider
      end

      def type
        output = modalities.output
        return 'embedding' if output.include?('embeddings')
        return 'moderation' if output.include?('moderation')
        return 'image' if output.include?('image')
        return 'audio' if output.include?('audio')
        return 'video' if output.include?('video')

        'chat'
      end

      def to_h
        hash = {
          id: id,
          name: name,
          provider: provider,
          family: family,
          created_at: created_at,
          context_window: context_window,
          max_output_tokens: max_output_tokens
        }
        hash[:embedding_dimensions] = embedding_dimensions.to_h if embedding_dimensions
        hash.merge(
          knowledge_cutoff: knowledge_cutoff,
          modalities: modalities.to_h,
          capabilities: capabilities,
          pricing: pricing.to_h,
          metadata: metadata
        )
      end

      private

      def within_reasoning_budget?(budget)
        return false unless budget.is_a?(Numeric)

        minimum = minimum_reasoning_budget
        maximum = maximum_reasoning_budget
        return false if minimum && budget < minimum
        return false if maximum && budget > maximum

        true
      end

      def reasoning_options_from(data)
        data[:reasoning_options] || metadata[:reasoning_options] || metadata['reasoning_options']
      end

      def store_reasoning_options_metadata
        return unless reasoning_options.any?

        metadata.delete('reasoning_options')
        metadata[:reasoning_options] = reasoning_options
      end

      def normalize_reasoning_options(options)
        Array(options).filter_map do |option|
          next unless option.is_a?(Hash)

          normalized = option.to_h.transform_keys(&:to_sym)
          normalized[:type] = normalized[:type].to_s if normalized[:type]
          normalized[:values] = Array(normalized[:values]).map(&:to_s) if normalized.key?(:values)
          normalized
        end
      end
    end
  end
end
