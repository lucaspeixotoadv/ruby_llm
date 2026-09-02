# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Model::Info do
  subject(:info) { described_class.new(data) }

  let(:data) do
    {
      id: 'gpt-5',
      name: 'GPT-5',
      provider: 'openai',
      family: 'gpt',
      created_at: '2026-02-20 00:00:00 UTC',
      context_window: 400_000,
      max_output_tokens: 128_000,
      knowledge_cutoff: '2025-10-01',
      modalities: { input: %w[text image], output: %w[text] },
      capabilities: %w[function_calling streaming vision structured_output],
      pricing: { text_tokens: { standard: { input: 2.50, output: 10.00 } } },
      metadata: {
        description: 'A test model',
        reasoning_options: [
          { type: 'effort', values: %w[low medium high] },
          { type: 'budget_tokens', min: 1024 }
        ]
      }
    }
  end

  describe '#initialize' do
    it 'assigns basic attributes' do
      expect(info).to have_attributes(
        id: 'gpt-5',
        name: 'GPT-5',
        provider: 'openai',
        family: 'gpt',
        context_window: 400_000,
        max_output_tokens: 128_000
      )
    end

    it 'parses created_at and knowledge_cutoff' do
      expect(info.created_at).to be_a(Time)
      expect(info.knowledge_cutoff).to be_a(Date)
    end

    it 'normalizes time to UTC' do
      info = described_class.new(created_at: '2026-02-20 00:00:00 +0700')
      expect(info.created_at).to be_utc
      expect(info.created_at).to eq Time.new(2026, 2, 19, 17, 0, 0, '+00:00')
    end

    it 'builds modalities' do
      expect(info.modalities).to be_a(RubyLLM::Model::Modalities)
      expect(info.modalities.input).to eq(%w[text image])
      expect(info.modalities.output).to eq(%w[text])
    end

    it 'builds pricing' do
      expect(info.pricing).to be_a(RubyLLM::Model::Pricing)
    end

    it 'defaults missing optional fields' do
      minimal = described_class.new(id: 'test', name: 'Test', provider: 'openai')

      expect(minimal.capabilities).to eq([])
      expect(minimal.metadata).to eq({})
      expect(minimal.reasoning_options).to eq([])
      expect(minimal.modalities.input).to eq([])
    end
  end

  describe '.default' do
    subject(:default_info) { described_class.default('my-custom-model', 'openai') }

    it 'creates an info with assumed capabilities' do
      expect(default_info).to have_attributes(
        id: 'my-custom-model',
        provider: 'openai'
      )
      expect(default_info.capabilities).to include('function_calling', 'streaming')
      expect(default_info.metadata).to have_key(:warning)
    end
  end

  describe '#supports?' do
    it 'returns true for included capabilities' do
      expect(info.supports?(:function_calling)).to be true
      expect(info.supports?('streaming')).to be true
    end

    it 'returns false for missing capabilities' do
      expect(info.supports?(:batch)).to be false
    end
  end

  describe 'capability predicates' do
    it 'responds to dynamic capability methods' do
      expect(info.function_calling?).to be true
      expect(info.structured_output?).to be true
      expect(info.streaming?).to be true
      expect(info.batch?).to be false
      expect(info.reasoning?).to be false
    end
  end

  describe '#supports_vision?' do
    it 'returns true when image is in input modalities' do
      expect(info.supports_vision?).to be true
    end

    it 'returns false when image is not in input modalities' do
      text_only = described_class.new(data.merge(modalities: { input: %w[text], output: %w[text] }))
      expect(text_only.supports_vision?).to be false
    end
  end

  describe '#reasoning_options' do
    it 'normalizes metadata reasoning options' do
      expect(info.reasoning_options).to eq(
        [
          { type: 'effort', values: %w[low medium high] },
          { type: 'budget_tokens', min: 1024 }
        ]
      )
    end

    it 'accepts top-level reasoning options and stores them in metadata' do
      top_level_info = described_class.new(
        data.merge(
          reasoning_options: [
            { 'type' => 'effort', 'values' => %i[low high] }
          ],
          metadata: {}
        )
      )

      expect(top_level_info.reasoning_options).to eq([{ type: 'effort', values: %w[low high] }])
      expect(top_level_info.metadata[:reasoning_options]).to eq([{ type: 'effort', values: %w[low high] }])
    end

    it 'accepts string-keyed metadata reasoning options' do
      legacy_info = described_class.new(
        data.merge(
          metadata: {
            'reasoning_options' => [
              { 'type' => 'effort', 'values' => %i[low high] }
            ]
          }
        )
      )

      expect(legacy_info.reasoning_options).to eq([{ type: 'effort', values: %w[low high] }])
    end

    it 'prefers top-level reasoning options over metadata when both are present' do
      info = described_class.new(
        data.merge(
          reasoning_options: [
            { 'type' => 'effort', 'values' => %w[low high] }
          ],
          metadata: {
            reasoning_options: [
              { 'type' => 'budget_tokens', 'min' => 1024 }
            ]
          }
        )
      )

      expect(info.reasoning_options).to eq([{ type: 'effort', values: %w[low high] }])
    end

    it 'normalizes option values to strings' do
      symbol_info = described_class.new(
        data.merge(
          metadata: {
            reasoning_options: [
              { 'type' => 'effort', 'values' => %i[low high] }
            ]
          }
        )
      )

      expect(symbol_info.reasoning_options).to eq([{ type: 'effort', values: %w[low high] }])
    end

    it 'returns option values by type' do
      expect(info.reasoning_option_values(:effort)).to eq(%w[low medium high])
      expect(info.reasoning_option_values(:budget_tokens)).to eq([])
    end
  end

  describe '#type' do
    it 'returns chat for text output models' do
      expect(info.type).to eq('chat')
    end

    it 'returns embedding for output models that include embeddings' do
      embedding = described_class.new(data.merge(modalities: { input: %w[text], output: %w[embeddings] }))
      expect(embedding.type).to eq('embedding')
    end

    it 'returns image for output models that include image' do
      image = described_class.new(data.merge(modalities: { input: %w[text], output: %w[image] }))
      expect(image.type).to eq('image')
    end

    it 'returns image for mixed text+image output models' do
      image = described_class.new(data.merge(modalities: { input: %w[text], output: %w[text image] }))
      expect(image.type).to eq('image')
    end

    it 'returns audio for mixed text+audio output models' do
      audio = described_class.new(data.merge(modalities: { input: %w[text], output: %w[text audio] }))
      expect(audio.type).to eq('audio')
    end

    it 'returns embedding for mixed text+embeddings output models' do
      embedding = described_class.new(data.merge(modalities: { input: %w[text], output: %w[text embeddings] }))
      expect(embedding.type).to eq('embedding')
    end

    it 'returns moderation for mixed text+moderation output models' do
      moderation = described_class.new(data.merge(modalities: { input: %w[text], output: %w[text moderation] }))
      expect(moderation.type).to eq('moderation')
    end

    it 'returns video for video output models' do
      video = described_class.new(data.merge(modalities: { input: %w[text], output: %w[video] }))
      expect(video.type).to eq('video')
    end
  end

  describe '#display_name' do
    it 'returns the name' do
      expect(info.display_name).to eq('GPT-5')
    end
  end

  describe '#label' do
    it 'returns provider and display name' do
      expect(info.label).to eq('OpenAI - GPT-5')
    end
  end

  describe '#max_tokens' do
    it 'returns max_output_tokens' do
      expect(info.max_tokens).to eq(128_000)
    end
  end

  describe '#input_price_per_million and #output_price_per_million' do
    it 'delegates to pricing' do
      expect(info.input_price_per_million).to eq(info.pricing.text_tokens.input)
      expect(info.output_price_per_million).to eq(info.pricing.text_tokens.output)
    end
  end

  describe 'cache price helpers' do
    it 'delegates to cache read and write pricing' do
      info = described_class.new(
        data.merge(
          pricing: {
            text_tokens: {
              standard: {
                cache_read_input_per_million: 0.5,
                cache_write_input_per_million: 2.5
              }
            }
          }
        )
      )

      expect(info.cache_read_input_price_per_million).to eq(0.5)
      expect(info.cache_write_input_price_per_million).to eq(2.5)
      expect(info.cached_input_price_per_million).to eq(0.5)
      expect(info.cache_creation_input_price_per_million).to eq(2.5)
    end
  end

  describe '#cost_for' do
    it 'builds a Cost for the supplied tokens' do
      info = described_class.new(
        data.merge(
          pricing: {
            text_tokens: {
              standard: {
                input_per_million: 2.50,
                output_per_million: 10.00
              }
            }
          }
        )
      )
      tokens = RubyLLM::Tokens.new(input: 1_000, output: 2_000)

      expect(info.cost_for(tokens).total).to eq(0.0225)
    end
  end

  describe '#to_h' do
    it 'returns a hash representation' do
      hash = info.to_h

      expect(hash[:id]).to eq('gpt-5')
      expect(hash[:provider]).to eq('openai')
      expect(hash[:modalities]).to be_a(Hash)
      expect(hash[:pricing]).to be_a(Hash)
      expect(hash[:capabilities]).to include('function_calling')
      expect(hash).not_to have_key(:reasoning_options)
      expect(hash[:metadata][:reasoning_options]).to eq(
        [
          { type: 'effort', values: %w[low medium high] },
          { type: 'budget_tokens', min: 1024 }
        ]
      )
    end

    it 'omits embedding_dimensions for a model that does not embed' do
      expect(info.to_h).not_to have_key(:embedding_dimensions)
    end
  end

  describe 'embedding dimensions' do
    subject(:embedder) do
      described_class.new(
        id: 'gemini-embedding-001',
        provider: 'gemini',
        max_output_tokens: 1,
        embedding_dimensions: {
          default: 3072, configurable: true, supported: [768, 1536, 3072], min: 128, max: 3072
        },
        modalities: { input: %w[text], output: %w[embeddings] }
      )
    end

    it 'is nil for a model that does not embed' do
      expect(info.embedding_dimensions).to be_nil
      expect(info.default_embedding_dimensions).to be_nil
      expect(info).not_to be_configurable_embedding_dimensions
      expect(info.supports_embedding_dimensions?(1536)).to be false
    end

    it 'builds an EmbeddingDimensions value object' do
      expect(embedder.embedding_dimensions).to be_a(RubyLLM::Model::EmbeddingDimensions)
      expect(embedder.default_embedding_dimensions).to eq(3072)
      expect(embedder).to be_configurable_embedding_dimensions
    end

    it 'keeps the vector width independent of the output token limit' do
      expect(embedder.max_output_tokens).to eq(1)
      expect(embedder.max_tokens).to eq(1)
      expect(embedder.default_embedding_dimensions).to eq(3072)
    end

    it 'does not read a token limit as a width when the width is absent' do
      widthless = described_class.new(
        id: 'text-embedding-mystery',
        provider: 'openai',
        max_output_tokens: 1536,
        modalities: { input: %w[text], output: %w[embeddings] }
      )

      expect(widthless.default_embedding_dimensions).to be_nil
    end

    it 'accepts a bare integer for a fixed-width model' do
      fixed = described_class.new(id: 'mistral-embed', provider: 'mistral', embedding_dimensions: 1024)

      expect(fixed.default_embedding_dimensions).to eq(1024)
      expect(fixed).not_to be_configurable_embedding_dimensions
    end

    it 'round-trips through to_h' do
      round_tripped = described_class.new(embedder.to_h)

      expect(round_tripped.embedding_dimensions).to eq(embedder.embedding_dimensions)
      expect(round_tripped.max_output_tokens).to eq(1)
    end
  end

  describe '#status' do
    it 'reports the status the registry stated' do
      model = described_class.new(id: 'x', provider: 'anthropic', metadata: { status: 'deprecated' })

      expect(model.status).to eq('deprecated')
      expect(model).to be_deprecated
    end

    it 'reports nil when the registry stated none' do
      expect(info.status).to be_nil
      expect(info).not_to be_deprecated
    end

    it 'reports a non-deprecated status without calling it deprecated' do
      model = described_class.new(id: 'x', provider: 'anthropic', metadata: { status: 'alpha' })

      expect(model.status).to eq('alpha')
      expect(model).not_to be_deprecated
    end
  end
end
