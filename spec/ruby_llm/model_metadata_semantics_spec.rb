# frozen_string_literal: true

require 'spec_helper'

# Two facts about a model that RubyLLM must carry without reinterpreting them.
#
#   limit.output          -> how many *tokens* a model may generate
#   embedding_dimensions  -> how wide a vector an embedding model returns
#
# models.dev has no field for the second, so its embedding entries put a number
# in limit.output that is sometimes a width (3072 for text-embedding-3-large)
# and sometimes neither (1 for gemini-embedding-001). A consumer that reads the
# token limit as a width therefore gets a plausible answer for one model and a
# 1-dimensional vector for the next. These examples pin the two apart.
#
# metadata.status is the other half: models.dev owns it, and RubyLLM's only job
# is to hand it over unchanged - including handing over nothing when the source
# says nothing. Availability is never decided here, and never from a model id.
RSpec.describe 'model metadata semantics' do # rubocop:disable RSpec/DescribeClass
  # A models.dev payload for gemini-embedding-001, verbatim in the parts that
  # matter: a 1-token "output limit" and no field for the vector width at all.
  let(:gemini_embedding_payload) do
    {
      id: 'gemini-embedding-001',
      name: 'Gemini Embedding 001',
      limit: { context: 2048, output: 1 },
      modalities: { input: ['text'], output: ['embeddings'] },
      cost: { input: 0.15 }
    }
  end

  let(:openai_embedding_payload) do
    {
      id: 'text-embedding-3-large',
      name: 'Text Embedding 3 Large',
      limit: { context: 8191, output: 3072 },
      modalities: { input: ['text'], output: ['embeddings'] }
    }
  end

  def models_dev_info(payload, slug, key)
    RubyLLM::Model::Info.new(RubyLLM::Models.models_dev_model_to_info(payload, slug, key))
  end

  describe 'limit.output keeps meaning output tokens' do
    it 'maps limit.output to max_output_tokens and nowhere else' do
      model = models_dev_info(gemini_embedding_payload, 'gemini', 'google')

      expect(model.max_output_tokens).to eq(1)
      expect(model.metadata[:limit]).to eq(context: 2048, output: 1)
    end

    it 'does not let limit.output become the vector width' do
      model = models_dev_info(gemini_embedding_payload, 'gemini', 'google')

      expect(model.default_embedding_dimensions).to eq(3072)
      expect(model.default_embedding_dimensions).not_to eq(model.max_output_tokens)
    end

    it 'does not let a limit.output that happens to look like a width become one' do
      model = models_dev_info(openai_embedding_payload, 'openai', 'openai')

      # The two agree here by coincidence, so prove the width came from the
      # provider's capabilities rather than from the token limit: strip the
      # limit and the width is unchanged.
      widthless = models_dev_info(openai_embedding_payload.merge(limit: { context: 8191 }), 'openai', 'openai')

      expect(model.default_embedding_dimensions).to eq(3072)
      expect(widthless.max_output_tokens).to be_nil
      expect(widthless.default_embedding_dimensions).to eq(3072)
    end

    it 'leaves a chat model without any embedding width' do
      model = models_dev_info(
        { id: 'gemini-2.5-flash', limit: { context: 1_048_576, output: 65_536 },
          modalities: { input: %w[text image], output: ['text'] } },
        'gemini',
        'google'
      )

      expect(model.max_output_tokens).to eq(65_536)
      expect(model.embedding_dimensions).to be_nil
      expect(model.default_embedding_dimensions).to be_nil
    end
  end

  describe 'configurable widths survive as more than a single integer' do
    it 'represents gemini-embedding-001 default, range and recommended sizes' do
      model = models_dev_info(gemini_embedding_payload, 'gemini', 'google')

      expect(model.embedding_dimensions.to_h).to eq(
        default: 3072, configurable: true, supported: [768, 1536, 3072], min: 128, max: 3072
      )
      expect(model).to be_configurable_embedding_dimensions
      expect(model.supports_embedding_dimensions?(768)).to be true
      expect(model.supports_embedding_dimensions?(1536)).to be true
      expect(model.supports_embedding_dimensions?(4096)).to be false
    end

    it 'marks a fixed-width model as not configurable' do
      model = models_dev_info(
        { id: 'text-embedding-ada-002', limit: { context: 8192, output: 1536 },
          modalities: { input: ['text'], output: ['embeddings'] } },
        'openai',
        'openai'
      )

      expect(model).not_to be_configurable_embedding_dimensions
      expect(model.default_embedding_dimensions).to eq(1536)
      expect(model.supports_embedding_dimensions?(256)).to be false
    end

    it 'survives the JSON round-trip the registry file performs' do
      model = models_dev_info(gemini_embedding_payload, 'gemini', 'google')
      reloaded = RubyLLM::Model::Info.new(
        JSON.parse(JSON.generate([model.to_h]), symbolize_names: true).first
      )

      expect(reloaded.embedding_dimensions).to eq(model.embedding_dimensions)
      expect(reloaded.max_output_tokens).to eq(1)
    end
  end

  describe 'the shipped registry' do
    let(:models) { RubyLLM::Models.new }
    let(:embedding_models) { models.embedding_models.all }

    it 'gives every embedding model whose provider documents a width one of its own' do
      # Azure is excluded on purpose: its ids are deployment names the account
      # owner chooses, so there is no id to match a documented width against.
      # An unknown width stays nil rather than becoming a guess.
      documented = embedding_models.reject { |m| m.provider == 'azure' }
      missing = documented.reject(&:embedding_dimensions).map { |m| "#{m.provider}:#{m.id}" }

      expect(documented).not_to be_empty
      expect(missing).to be_empty
    end

    it 'leaves a width unknown rather than guessed when nothing documents it' do
      unknown = embedding_models.reject(&:embedding_dimensions)

      expect(unknown.map(&:default_embedding_dimensions).uniq).to eq([nil]).or be_empty
    end

    it 'never reports a width by reading the token limit' do
      # If a width were derived from max_output_tokens, these would agree
      # everywhere. They must not: the fields are unrelated.
      disagreeing = embedding_models.count do |model|
        model.default_embedding_dimensions != model.max_output_tokens
      end

      expect(disagreeing).to be_positive
    end

    it 'records gemini-embedding-001 as 3072-wide despite its 1-token output limit' do
      model = models.find('gemini-embedding-001', 'gemini')

      expect(model.max_output_tokens).to eq(1)
      expect(model.default_embedding_dimensions).to eq(3072)
      expect(model.embedding_dimensions.supported).to eq([768, 1536, 3072])
    end

    it 'records mistral-embed as 1024-wide despite a larger token limit' do
      model = models.find('mistral-embed-2312', 'mistral')

      expect(model.max_output_tokens).to eq(8192)
      expect(model.default_embedding_dimensions).to eq(1024)
    end

    it 'never lands a width on a model that does not embed' do
      # Azure's listing reports no modalities at all, so its entries fall back
      # to "chat" - matching on the id is what keeps the assertion about the
      # width rather than about that gap.
      stray = models.all.select(&:embedding_dimensions).reject { |m| m.id.downcase.include?('embed') }

      expect(stray).to be_empty
    end

    it 'leaves models that declare text output without an embedding width' do
      text_models = models.all.select { |m| m.modalities.output.include?('text') }

      expect(text_models.select(&:embedding_dimensions)).to be_empty
    end
  end

  describe 'metadata.status' do
    let(:deprecated_payload) do
      {
        id: 'claude-3-haiku-20240307',
        name: 'Claude 3 Haiku',
        status: 'deprecated',
        limit: { context: 200_000, output: 4096 },
        modalities: { input: ['text'], output: ['text'] }
      }
    end

    it 'is carried from the models.dev payload into metadata' do
      model = models_dev_info(deprecated_payload, 'anthropic', 'anthropic')

      expect(model.metadata[:status]).to eq('deprecated')
      expect(model.status).to eq('deprecated')
      expect(model).to be_deprecated
    end

    it 'stays absent when models.dev states nothing' do
      model = models_dev_info(deprecated_payload.except(:status), 'anthropic', 'anthropic')

      expect(model.metadata).not_to have_key(:status)
      expect(model.status).to be_nil
      expect(model).not_to be_deprecated
    end

    it 'is not overwritten when provider data is merged in' do
      models_dev_model = models_dev_info(deprecated_payload, 'anthropic', 'anthropic')
      provider_model = RubyLLM::Model::Info.new(
        id: 'claude-3-haiku-20240307',
        name: 'Claude 3 Haiku (provider listing)',
        provider: 'anthropic',
        metadata: { source: 'provider' }
      )

      merged = RubyLLM::Models.add_provider_metadata(models_dev_model, provider_model)

      expect(merged.status).to eq('deprecated')
      expect(merged.metadata[:source]).to eq('models.dev')
    end

    it 'is not invented for a model the provider listing alone knows about' do
      provider_only = RubyLLM::Model::Info.new(
        id: 'some-provider-only-model',
        name: 'Provider Only',
        provider: 'anthropic',
        metadata: { source: 'provider' }
      )

      merged = RubyLLM::Models.merge_models([provider_only], [])

      expect(merged.first.status).to be_nil
    end

    it 'survives the JSON round-trip the registry file performs' do
      model = models_dev_info(deprecated_payload, 'anthropic', 'anthropic')
      reloaded = RubyLLM::Model::Info.new(
        JSON.parse(JSON.generate([model.to_h]), symbolize_names: true).first
      )

      expect(reloaded.status).to eq('deprecated')
    end

    it 'reads a status stored under a string key, as a database column returns it' do
      model = RubyLLM::Model::Info.new(id: 'x', provider: 'anthropic', metadata: { 'status' => 'deprecated' })

      expect(model.status).to eq('deprecated')
      expect(model).to be_deprecated
    end

    it 'survives a refresh that falls back to cached models.dev data' do
      cached = models_dev_info(deprecated_payload, 'anthropic', 'anthropic')
      preserved = RubyLLM::Models.merge_with_existing(
        [cached],
        { models: [], fetched_providers: [], configured_names: [], failed: [] },
        { models: [], fetched: false }
      )

      expect(preserved.map(&:status)).to eq(['deprecated'])
    end

    it 'is preserved verbatim in the shipped registry' do
      statuses = RubyLLM::Models.new.all.filter_map(&:status).uniq

      expect(statuses).to include('deprecated')
    end

    it 'does not decide availability from a model id' do
      # models.dev states no status for the gemini-2.5 line, so neither does
      # RubyLLM. Correcting that belongs to the source, not to a local rule.
      gemini_two_five = RubyLLM::Models.new.all.select { |m| m.id.start_with?('gemini-2.5') }

      expect(gemini_two_five).not_to be_empty
      expect(gemini_two_five.map(&:status).uniq).to eq([nil])
    end
  end
end
