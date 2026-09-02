# frozen_string_literal: true

require 'spec_helper'

# Guards the facts the registry records about the Gemini models this fork
# depends on. These come from the live ListModels response (context window,
# output limit, thinking, caching) and from Google's own pricing page
# (the prices and the date the introductory price expires).
RSpec.describe 'Gemini registry' do # rubocop:disable RSpec/DescribeClass
  def gemini_model(id)
    RubyLLM.models.find(id, :gemini)
  end

  describe 'recent flash models' do
    %w[gemini-3.6-flash gemini-3.7-flash].each do |id|
      context "with #{id}" do
        subject(:model) { gemini_model(id) }

        it 'is registered against the Gemini provider' do
          expect(model.provider).to eq('gemini')
          expect(model.id).to eq(id)
        end

        it 'records the limits the API reports' do
          expect(model.context_window).to eq(1_048_576)
          expect(model.max_output_tokens).to eq(65_536)
        end

        it 'records the capabilities the API reports' do
          expect(model.capabilities).to include('function_calling', 'structured_output', 'reasoning', 'caching')
        end

        it 'accepts multimodal input and answers in text' do
          expect(model.modalities.input).to include('text', 'image', 'audio', 'video')
          expect(model.modalities.output).to eq(['text'])
          expect(model.supports_vision?).to be(true)
          expect(model.type).to eq('chat')
        end

        it 'carries both the introductory price and the price that replaces it' do
          expect(model.pricing.scheduled?).to be(true)

          promo = model.pricing.at(Time.utc(2026, 6, 1)).text_tokens
          standard = model.pricing.at(Time.utc(2027, 6, 1)).text_tokens

          expect(promo.input).to eq(0.75)
          expect(promo.output).to eq(3.75)
          expect(promo.cache_read_input).to eq(0.075)
          expect(standard.input).to eq(1.50)
          expect(standard.output).to eq(7.50)
          expect(standard.cache_read_input).to eq(0.15)
        end

        it 'computes a cost from the price in effect when the call was made' do
          tokens = RubyLLM::Tokens.new(input: 1_000_000, output: 1_000_000)

          promo = RubyLLM::Cost.new(tokens:, model:, at: Time.utc(2026, 6, 1))
          standard = RubyLLM::Cost.new(tokens:, model:, at: Time.utc(2027, 6, 1))

          expect(promo.total).to be_within(1e-9).of(4.50)
          expect(standard.total).to be_within(1e-9).of(9.00)
        end
      end
    end
  end

  describe 'models whose price we do not know' do
    it 'records no pricing rather than a fallback' do
      unpriced = RubyLLM.models.select { |m| m.provider == 'gemini' && m.pricing.to_h.empty? }

      expect(unpriced).not_to be_empty
      expect(unpriced.map(&:id)).to include('lyria-3-pro-preview', 'veo-3.1-generate-preview')
    end

    it 'yields no cost at all rather than a cost of zero' do
      model = gemini_model('lyria-3-pro-preview')
      cost = RubyLLM::Cost.new(tokens: RubyLLM::Tokens.new(input: 1_000, output: 1_000), model:)

      expect(cost.total).to be_nil
    end

    it 'no longer prices unrelated models at the flash-lite rate' do
      # 0.075/0.30 is the real gemini-2.0-flash-lite price, and it used to be
      # handed out as a fallback to every Gemini model with no price of its own
      # - video, music, image and research models included.
      guessed = RubyLLM.models.select do |m|
        m.provider == 'gemini' &&
          !m.id.include?('flash-lite') &&
          m.pricing.text_tokens.input&.between?(0.0749, 0.0751) &&
          m.pricing.text_tokens.output&.between?(0.299, 0.301)
      end

      expect(guessed.map(&:id)).to be_empty
    end
  end

  describe 'models the provider stopped listing' do
    # Gemini's ListModels does not return the imagen and veo generation models,
    # and what a key may see varies. Absence from a listing is not evidence a
    # model was retired, and dropping it breaks calls that still work.
    it 'keeps a model a refresh did not see' do
      expect { gemini_model('imagen-4.0-generate-001') }.not_to raise_error
      expect { gemini_model('veo-3.0-generate-001') }.not_to raise_error
    end

    it 'does not let a preserved model keep a price the provider no longer states' do
      expect(gemini_model('veo-3.0-generate-001').pricing.to_h).to eq({})
      expect(gemini_model('gemini-robotics-er-1.5-preview').pricing.to_h).to eq({})
    end

    it 'keeps a preserved model priced when the provider still prices it' do
      expect(gemini_model('imagen-4.0-generate-001').pricing.text_tokens.input).to eq(0.03)
    end
  end

  describe 'merging a curated schedule with secondary data' do
    it 'keeps the dated schedule instead of a flat secondary price' do
      scheduled = RubyLLM::Model::Info.new(
        id: 'gemini-3.6-flash',
        provider: 'gemini',
        pricing: RubyLLM::Providers::Gemini::Capabilities.pricing_for('gemini-3.6-flash')
      )
      from_models_dev = RubyLLM::Model::Info.new(
        id: 'gemini-3.6-flash',
        provider: 'gemini',
        pricing: { text_tokens: { standard: { input_per_million: 0.75, output_per_million: 3.75 } } },
        metadata: { source: 'models.dev' }
      )

      merged = RubyLLM::Models.add_provider_metadata(from_models_dev, scheduled)

      expect(merged.pricing.scheduled?).to be(true)
      expect(merged.pricing.at(Time.utc(2027, 6, 1)).text_tokens.input).to eq(1.50)
    end

    it 'still takes the secondary price when the provider has no schedule' do
      provider_model = RubyLLM::Model::Info.new(
        id: 'gemini-2.0-flash',
        provider: 'gemini',
        pricing: { text_tokens: { standard: { input_per_million: 0.10, output_per_million: 0.40 } } }
      )
      from_models_dev = RubyLLM::Model::Info.new(
        id: 'gemini-2.0-flash',
        provider: 'gemini',
        pricing: { text_tokens: { standard: { input_per_million: 0.11, output_per_million: 0.41 } } },
        metadata: { source: 'models.dev', cost: { input: 0.11, output: 0.41 } }
      )

      merged = RubyLLM::Models.add_provider_metadata(from_models_dev, provider_model)

      expect(merged.pricing.text_tokens.input).to eq(0.11)
    end

    it 'does not launder an old provider guess back in as a models.dev price' do
      # A models.dev entry with no cost of its own never priced anything: any
      # price on it was written there by an earlier refresh from the provider.
      # Re-reading it must not outrank what the provider says today.
      provider_model = RubyLLM::Model::Info.new(id: 'gemma-4-31b-it', provider: 'gemini')
      stale = RubyLLM::Model::Info.new(
        id: 'gemma-4-31b-it',
        provider: 'gemini',
        pricing: { text_tokens: { standard: { input_per_million: 0.075, output_per_million: 0.30 } } },
        metadata: { source: 'models.dev' }
      )

      merged = RubyLLM::Models.add_provider_metadata(stale, provider_model)

      expect(merged.pricing.to_h).to eq({})
    end
  end
end
