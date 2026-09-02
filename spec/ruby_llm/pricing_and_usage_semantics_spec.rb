# frozen_string_literal: true

require 'spec_helper'

# Three states must stay distinguishable everywhere pricing and usage are
# modelled:
#
#   known    -> a number a consumer can compute with
#   free     -> 0.0, a price the provider really charges
#   unknown  -> nil, the absence of information
#
# Collapsing "unknown" into 0 is the bug these examples guard against: it turns
# a measurement that never happened into a confident claim that it was zero.
RSpec.describe 'pricing and usage semantics' do # rubocop:disable RSpec/DescribeClass
  def response_double(body)
    instance_double(Faraday::Response, body: body)
  end

  # The Gemini modules are mixed into the provider rather than exposed as
  # module functions, so exercise them through a real provider instance.
  def gemini_provider
    config = RubyLLM::Configuration.new
    config.gemini_api_key = 'test'
    RubyLLM::Providers::Gemini.new(config)
  end

  describe RubyLLM::Providers::Gemini::Capabilities do
    it 'reports no pricing for a model whose price it does not know' do
      pricing = described_class.pricing_for('gemini-9.9-flash-unreleased')

      expect(pricing).to eq({})
    end

    it 'does not hand unknown models the flash-lite price as a fallback' do
      unknown = %w[
        veo-3.1-generate-preview
        lyria-3-pro-preview
        gemma-4-31b-it
        nano-banana-pro-preview
        deep-research-preview-04-2026
      ]

      unknown.each do |model_id|
        expect(described_class.pricing_for(model_id)).to eq({}),
                                                         "expected #{model_id} to have no pricing, " \
                                                         "got #{described_class.pricing_for(model_id).inspect}"
      end
    end

    it 'records both sides of an announced price change rather than only today' do
      schedule = described_class.pricing_for('gemini-3.6-flash').dig(:text_tokens, :standard, :schedule)

      expect(schedule).to be_an(Array)
      expect(schedule.size).to be >= 2
      expect(schedule.map { |entry| entry[:input_per_million] }).to contain_exactly(0.75, 1.50)
    end

    it 'still reports the prices it genuinely knows' do
      pricing = described_class.pricing_for('gemini-2.0-flash')

      expect(pricing.dig(:text_tokens, :standard)).to eq(
        input_per_million: 0.10,
        output_per_million: 0.40
      )
    end

    it 'reports a genuinely free model as free rather than as unpriced' do
      pricing = described_class.pricing_for('embedding-001')

      expect(pricing.dig(:text_tokens, :standard)).to eq(
        input_per_million: 0.0,
        output_per_million: 0.0
      )
    end

    it 'does not claim billed embedding models are free' do
      expect(described_class.pricing_for('gemini-embedding-001')).to eq({})
    end
  end

  describe RubyLLM::Providers::OpenAI::Capabilities do
    it 'reports no pricing for a model family it does not price' do
      expect(described_class.pricing_for('some-unreleased-model')).to eq({})
      expect(described_class.pricing_for('sora-2')).to eq({})
    end

    it 'still reports the prices it genuinely knows' do
      expect(described_class.pricing_for('gpt-4o').dig(:text_tokens, :standard)).to eq(
        input_per_million: 2.50,
        output_per_million: 10.00
      )
    end
  end

  describe RubyLLM::Model::Pricing do
    it 'keeps a known price of zero instead of dropping it' do
      pricing = described_class.new(
        text_tokens: { standard: { input_per_million: 0.0, output_per_million: 0.0 } }
      )

      expect(pricing.text_tokens.input).to eq(0.0)
      expect(pricing.text_tokens.output).to eq(0.0)
    end

    it 'keeps an unknown price absent' do
      pricing = described_class.new({})

      expect(pricing.text_tokens.input).to be_nil
      expect(pricing.text_tokens.output).to be_nil
    end

    it 'distinguishes free from unknown' do
      free = described_class.new(text_tokens: { standard: { input_per_million: 0.0 } })
      unknown = described_class.new({})

      expect(free.text_tokens.input).not_to eq(unknown.text_tokens.input)
    end
  end

  describe RubyLLM::Cost do
    let(:priced_model) do
      RubyLLM::Model::Info.new(
        id: 'priced-model',
        name: 'Priced Model',
        provider: 'openai',
        pricing: { text_tokens: { standard: { input_per_million: 1.0, output_per_million: 2.0 } } }
      )
    end

    let(:free_model) do
      RubyLLM::Model::Info.new(
        id: 'free-model',
        name: 'Free Model',
        provider: 'gemini',
        pricing: { text_tokens: { standard: { input_per_million: 0.0, output_per_million: 0.0 } } }
      )
    end

    let(:unpriced_model) do
      RubyLLM::Model::Info.new(id: 'unpriced-model', name: 'Unpriced Model', provider: 'gemini')
    end

    it 'still computes cost for models with known pricing' do
      cost = described_class.new(tokens: RubyLLM::Tokens.new(input: 1_000, output: 2_000), model: priced_model)

      expect(cost.input).to be_within(1e-12).of(0.001)
      expect(cost.output).to be_within(1e-12).of(0.004)
      expect(cost.total).to be_within(1e-12).of(0.005)
    end

    it 'reports zero cost for a model that is genuinely free' do
      cost = described_class.new(tokens: RubyLLM::Tokens.new(input: 1_000, output: 2_000), model: free_model)

      expect(cost.total).to eq(0.0)
      expect(cost.missing?(:input)).to be(false)
    end

    it 'does not report an artificially zero cost when pricing is unknown' do
      cost = described_class.new(tokens: RubyLLM::Tokens.new(input: 1_000, output: 2_000), model: unpriced_model)

      expect(cost.input).to be_nil
      expect(cost.output).to be_nil
      expect(cost.total).to be_nil
      expect(cost.missing?(:input)).to be(true)
    end
  end

  describe RubyLLM::Embedding do
    it 'treats unreported usage as unknown' do
      embedding = described_class.new(vectors: [0.1, 0.2], model: 'gemini-embedding-001')

      expect(embedding.input_tokens).to be_nil
      expect(embedding.input_tokens?).to be(false)
      expect(embedding.cost).to be_nil
    end

    it 'keeps reported usage, including a genuine zero' do
      expect(described_class.new(vectors: [], model: 'm', input_tokens: 0).input_tokens).to eq(0)
      expect(described_class.new(vectors: [], model: 'm', input_tokens: 0).input_tokens?).to be(true)
    end
  end

  describe RubyLLM::Providers::Gemini::Embeddings do
    let(:embedder) { gemini_provider }

    it 'does not invent zero usage when the response reports none' do
      response = response_double('embeddings' => [{ 'values' => [0.1, 0.2] }])

      embedding = embedder.send(:parse_embedding_response, response, model: 'gemini-embedding-001', text: 'hi')

      expect(embedding.input_tokens).to be_nil
    end

    it 'captures the usageMetadata the batch embed API actually returns' do
      response = response_double(
        'embeddings' => [{ 'values' => [0.1, 0.2] }],
        'usageMetadata' => { 'promptTokenCount' => 7 }
      )

      embedding = embedder.send(:parse_embedding_response, response, model: 'gemini-embedding-001', text: 'hi')

      expect(embedding.input_tokens).to eq(7)
    end

    it 'translates dimensions to outputDimensionality' do
      payload = embedder.send(:render_embedding_payload, 'hi', model: 'gemini-embedding-001', dimensions: 1536)

      expect(payload[:requests].first).to include(outputDimensionality: 1536)
    end

    it 'omits outputDimensionality when no dimensions are requested' do
      payload = embedder.send(:render_embedding_payload, 'hi', model: 'gemini-embedding-001', dimensions: nil)

      expect(payload[:requests].first).not_to have_key(:outputDimensionality)
    end
  end

  describe RubyLLM::Providers::OpenAI::Embeddings do
    it 'does not invent zero usage when the response reports none' do
      response = response_double('data' => [{ 'embedding' => [0.1, 0.2] }])

      embedding = described_class.parse_embedding_response(response, model: 'text-embedding-3-small', text: 'hi')

      expect(embedding.input_tokens).to be_nil
    end

    it 'preserves usage the provider does report' do
      response = response_double(
        'data' => [{ 'embedding' => [0.1, 0.2] }],
        'usage' => { 'prompt_tokens' => 5 }
      )

      embedding = described_class.parse_embedding_response(response, model: 'text-embedding-3-small', text: 'hi')

      expect(embedding.input_tokens).to eq(5)
    end
  end

  describe RubyLLM::Providers::VertexAI::Embeddings do
    it 'does not invent zero usage when predictions carry no statistics' do
      response = response_double('predictions' => [{ 'embeddings' => { 'values' => [0.1] } }])

      embedding = described_class.parse_embedding_response(response, model: 'text-embedding-004', text: 'hi')

      expect(embedding.input_tokens).to be_nil
    end

    it 'sums the token counts predictions do report' do
      response = response_double(
        'predictions' => [
          { 'embeddings' => { 'values' => [0.1], 'statistics' => { 'token_count' => 3 } } },
          { 'embeddings' => { 'values' => [0.2], 'statistics' => { 'token_count' => 4 } } }
        ]
      )

      embedding = described_class.parse_embedding_response(response, model: 'text-embedding-004', text: %w[a b])

      expect(embedding.input_tokens).to eq(7)
    end
  end

  # Gemini::Streaming and the embedding modules are mixed into the same
  # provider classes. An embedding reader sharing a name with a streaming one
  # shadows it, and every streamed chunk silently loses that field.
  describe 'streaming and embedding token readers do not collide' do
    it 'reads input tokens off a streamed Gemini chunk' do
      chunk = gemini_provider.send(:build_chunk, {
                                     'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] } }],
                                     'usageMetadata' => { 'promptTokenCount' => 7, 'candidatesTokenCount' => 5 }
                                   })

      expect(chunk.input_tokens).to eq(7)
      expect(chunk.output_tokens).to eq(5)
    end

    it 'reads input tokens off a streamed Vertex AI chunk' do
      config = RubyLLM::Configuration.new
      config.vertexai_project_id = 'test'
      config.vertexai_location = 'us-central1'
      provider = RubyLLM::Providers::VertexAI.new(config)

      chunk = provider.send(:build_chunk, {
                              'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] } }],
                              'usageMetadata' => { 'promptTokenCount' => 7, 'candidatesTokenCount' => 5 }
                            })

      expect(chunk.input_tokens).to eq(7)
      expect(chunk.output_tokens).to eq(5)
    end
  end

  describe RubyLLM::Providers::Gemini::Chat do
    let(:chat) { gemini_provider }

    it 'leaves output tokens unknown when the response reports no counts' do
      response = response_double(
        'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] } }],
        'usageMetadata' => { 'promptTokenCount' => 5 },
        'modelVersion' => 'gemini-2.0-flash'
      )

      message = chat.send(:parse_completion_response, response)

      expect(message.input_tokens).to eq(5)
      expect(message.output_tokens).to be_nil
    end

    it 'sums the counts the response does report' do
      response = response_double(
        'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] } }],
        'usageMetadata' => {
          'promptTokenCount' => 5,
          'candidatesTokenCount' => 3,
          'thoughtsTokenCount' => 2
        },
        'modelVersion' => 'gemini-2.0-flash'
      )

      message = chat.send(:parse_completion_response, response)

      expect(message.output_tokens).to eq(5)
    end
  end

  describe RubyLLM::Providers::Gemini::Transcription do
    let(:transcriber) { gemini_provider }

    it 'leaves output tokens unknown when the response reports no counts' do
      response = response_double(
        'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hello' }] } }],
        'usageMetadata' => { 'promptTokenCount' => 11 }
      )

      transcription = transcriber.send(:parse_transcription_response, response, model: 'gemini-2.0-flash')

      expect(transcription.input_tokens).to eq(11)
      expect(transcription.output_tokens).to be_nil
    end

    it 'leaves both unknown when there is no usage metadata at all' do
      response = response_double('candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hello' }] } }])

      transcription = transcriber.send(:parse_transcription_response, response, model: 'gemini-2.0-flash')

      expect(transcription.input_tokens).to be_nil
      expect(transcription.output_tokens).to be_nil
    end
  end
end
