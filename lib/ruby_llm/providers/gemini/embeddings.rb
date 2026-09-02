# frozen_string_literal: true

module RubyLLM
  module Providers
    class Gemini
      # Embeddings methods for the Gemini API integration
      module Embeddings
        module_function

        def embedding_url(model:)
          "models/#{model}:batchEmbedContents"
        end

        def render_embedding_payload(text, model:, dimensions:)
          { requests: [text].flatten.map { |t| single_embedding_payload(t, model:, dimensions:) } }
        end

        def parse_embedding_response(response, model:, text:)
          body = response.body
          vectors = body['embeddings']&.map { |e| e['values'] }
          vectors = vectors.first if vectors&.length == 1 && !text.is_a?(Array)

          Embedding.new(vectors:, model:, input_tokens: extract_embedding_input_tokens(body))
        end

        # BatchEmbedContentsResponse carries an optional usageMetadata with
        # promptTokenCount. Older responses omit it entirely; then usage is
        # genuinely unknown and stays nil rather than being reported as 0.
        #
        # Named apart from Streaming#extract_input_tokens: both modules are
        # mixed into the same provider, so a shared name would shadow one.
        def extract_embedding_input_tokens(body)
          return nil unless body.is_a?(Hash)

          usage = body['usageMetadata']
          return nil unless usage.is_a?(Hash)

          prompt_tokens = usage['promptTokenCount']
          prompt_tokens&.to_i
        end

        private

        def single_embedding_payload(text, model:, dimensions:)
          {
            model: "models/#{model}",
            content: { parts: [{ text: text.to_s }] },
            outputDimensionality: dimensions
          }.compact
        end
      end
    end
  end
end
