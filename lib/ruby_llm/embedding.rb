# frozen_string_literal: true

module RubyLLM
  # Core embedding interface.
  #
  # `input_tokens` is nil when the provider did not report usage. nil means
  # "unknown", and is deliberately distinct from 0, which would claim the
  # provider measured and billed nothing.
  class Embedding
    attr_reader :vectors, :model, :input_tokens

    def initialize(vectors:, model:, input_tokens: nil)
      @vectors = vectors
      @model = model
      @input_tokens = input_tokens
    end

    # True when the provider reported token usage for this embedding.
    def input_tokens?
      !@input_tokens.nil?
    end

    # Cost of this embedding, as a RubyLLM::Cost.
    #
    # Returns nil when usage is unknown - there is nothing to price. When usage
    # is known but the model has no pricing, the Cost reports its components as
    # missing rather than as zero.
    def cost(model_info = nil)
      return nil unless input_tokens?

      Cost.new(tokens: Tokens.new(input: input_tokens), model: model_info || model)
    end

    # Embeds one text or an array of them.
    #
    # +task+ states what the embedding is for (:retrieval_document,
    # :retrieval_query, ...) so a provider that tunes vectors per task can be
    # asked for the right ones; +title+ names the document being embedded and
    # only goes with a document task. Both are optional: a call that omits
    # them behaves exactly as it did before they existed.
    def self.embed(text, # rubocop:disable Metrics/ParameterLists
                   model: nil,
                   provider: nil,
                   assume_model_exists: false,
                   context: nil,
                   dimensions: nil,
                   task: nil,
                   title: nil)
      task = Task.coerce(task, title:)
      config = context&.config || RubyLLM.config
      model ||= config.default_embedding_model
      model, provider_instance = Models.resolve(model, provider: provider, assume_exists: assume_model_exists,
                                                       config: config)
      model_id = model.id

      payload = {
        provider: provider_instance.slug,
        provider_class: provider_instance.class.name,
        model: model_id,
        model_info: model,
        input: text,
        dimensions: dimensions,
        task: task&.to_sym
      }

      RubyLLM.instrument('embedding.ruby_llm', payload, config: config) do |event|
        result = provider_instance.embed(text, model: model_id, dimensions:, task:, title:)
        event[:result] = result
        event[:response_model] = result.model
        event[:input_tokens] = result.input_tokens
        event[:embedding_dimensions] = vector_dimensions(result.vectors)
        event[:embedding_count] = embedding_count(result.vectors)
        result
      end
    end

    def self.vector_dimensions(vectors)
      return unless vectors.is_a?(Array)

      vector = vectors.first.is_a?(Array) ? vectors.first : vectors
      vector.length if vector.respond_to?(:length)
    end

    def self.embedding_count(vectors)
      return unless vectors.is_a?(Array)

      vectors.first.is_a?(Array) ? vectors.size : 1
    end
  end
end
