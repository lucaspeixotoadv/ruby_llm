# frozen_string_literal: true

module RubyLLM
  module Providers
    class VertexAI
      # Embeddings methods for the Vertex AI implementation
      module Embeddings
        module_function

        def embedding_url(model:)
          "projects/#{@config.vertexai_project_id}/locations/#{@config.vertexai_location}/publishers/google/models/#{model}:predict" # rubocop:disable Layout/LineLength
        end

        def render_embedding_payload(text, model:, dimensions:) # rubocop:disable Lint/UnusedMethodArgument
          {
            instances: [text].flatten.map { |t| { content: t.to_s } }
          }.tap do |payload|
            payload[:parameters] = { outputDimensionality: dimensions } if dimensions
          end
        end

        def parse_embedding_response(response, model:, text:)
          predictions = response.body['predictions']
          vectors = predictions&.map { |p| p.dig('embeddings', 'values') }
          vectors = vectors.first if vectors&.length == 1 && !text.is_a?(Array)

          Embedding.new(vectors:, model:, input_tokens: extract_embedding_input_tokens(predictions))
        end

        # Each prediction may carry embeddings.statistics.token_count. Sum the
        # counts that are actually present; when no prediction reports one,
        # usage is unknown and stays nil instead of being claimed as 0.
        #
        # Named apart from Gemini::Streaming#extract_input_tokens, which this
        # provider also mixes in: a shared name shadows it and silently strips
        # input tokens off every streamed chunk.
        def extract_embedding_input_tokens(predictions)
          counts = Array(predictions).filter_map do |prediction|
            next unless prediction.is_a?(Hash)

            prediction.dig('embeddings', 'statistics', 'token_count')
          end
          return nil if counts.empty?

          counts.sum(&:to_i)
        end
      end
    end
  end
end
