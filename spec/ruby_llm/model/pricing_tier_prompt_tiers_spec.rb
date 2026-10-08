# frozen_string_literal: true

require 'spec_helper'

# Some models charge more once the prompt grows past a size - Claude Haiku 5.5
# above 100,000 tokens, the Gemini Pro models above 200,000. The higher prices
# then apply to the whole call, and recording only the first set would price
# every long prompt too low.
RSpec.describe RubyLLM::Model::PricingTier do
  let(:tiered_prices) do
    {
      input_per_million: 0.10,
      output_per_million: 0.50,
      cache_read_input_per_million: 0.01,
      cache_write_input_per_million: 0.125,
      prompt_tiers: [
        {
          above_prompt_tokens: 100_000,
          input_per_million: 0.50,
          output_per_million: 2.50,
          cache_read_input_per_million: 0.05,
          cache_write_input_per_million: 0.625
        }
      ]
    }
  end

  let(:pricing) { RubyLLM::Model::Pricing.new(text_tokens: { standard: tiered_prices }) }

  describe 'resolving the prices for a prompt size' do
    it 'answers with the base prices up to the threshold, inclusive' do
      prices = pricing.text_tokens.for_prompt(100_000)

      expect([prices.input, prices.output, prices.cache_read_input, prices.cache_write_input])
        .to eq([0.10, 0.50, 0.01, 0.125])
    end

    it 'answers with the higher prices once the prompt goes past the threshold' do
      prices = pricing.text_tokens.for_prompt(100_001)

      expect([prices.input, prices.output, prices.cache_read_input, prices.cache_write_input])
        .to eq([0.50, 2.50, 0.05, 0.625])
    end

    it 'answers with the base prices when the prompt size is unknown' do
      expect(pricing.text_tokens.input).to eq(0.10)
      expect(pricing.text_tokens.for_prompt(nil).input).to eq(0.10)
    end

    it 'picks the highest tier the prompt goes past' do
      prices = described_class.new(
        input_per_million: 1.0,
        prompt_tiers: [{ above_prompt_tokens: 128_000, input_per_million: 3.0 },
                       { above_prompt_tokens: 32_000, input_per_million: 2.0 }]
      )

      expect([10_000, 64_000, 200_000].map { |size| prices.for_prompt(size).input_per_million }).to eq([1.0, 2.0, 3.0])
    end

    it 'does not lend a cheaper price to a tier that leaves it out' do
      prices = described_class.new(
        input_per_million: 1.0, cache_read_input_per_million: 0.1,
        prompt_tiers: [{ above_prompt_tokens: 200_000, input_per_million: 2.0 }]
      )

      expect(prices.for_prompt(300_000).cache_read_input_per_million).to be_nil
    end

    it 'drops a tier without a threshold or without prices' do
      prices = described_class.new(input_per_million: 1.0,
                                   prompt_tiers: [{ input_per_million: 2.0 }, { above_prompt_tokens: 10 }])

      expect(prices.prompt_tiers?).to be(false)
    end

    it 'survives a round trip through the registry representation' do
      round_tripped = RubyLLM::Model::Pricing.new(JSON.parse(JSON.generate(pricing.to_h), symbolize_names: true))

      expect(round_tripped.text_tokens.for_prompt(150_000).output).to eq(2.50)
      expect(round_tripped.to_h).to eq(pricing.to_h)
    end

    it 'combines with a dated schedule' do
      scheduled = RubyLLM::Model::Pricing.new(
        text_tokens: {
          standard: {
            schedule: [
              { effective_until: '2027-01-01', input_per_million: 1.0,
                prompt_tiers: [{ above_prompt_tokens: 200_000, input_per_million: 2.0 }] },
              { effective_from: '2027-01-01', input_per_million: 3.0,
                prompt_tiers: [{ above_prompt_tokens: 200_000, input_per_million: 6.0 }] }
            ]
          }
        }
      )

      expect(scheduled.at(Time.utc(2026, 6, 1)).text_tokens.for_prompt(250_000).input).to eq(2.0)
      expect(scheduled.text_tokens.for_prompt(250_000).at(Time.utc(2027, 6, 1)).input).to eq(6.0)
    end
  end

  describe RubyLLM::Cost do
    let(:model) do
      RubyLLM::Model::Info.new(id: 'tiered-model', name: 'Tiered Model', provider: 'anthropic', pricing: pricing.to_h)
    end

    it 'prices every component of a long prompt at the higher tier' do
      tokens = RubyLLM::Tokens.new(input: 150_000, output: 1_000_000, cached: 0, cache_creation: 0)
      cost = described_class.new(tokens:, model:)

      expect(cost.input).to be_within(1e-12).of(150_000 * 0.50 / 1_000_000)
      expect(cost.output).to be_within(1e-12).of(2.50)
    end

    # The prompt is everything the provider processed: what came from the cache
    # counts toward the size as much as the fresh input does.
    it 'counts what was read from and written to the cache toward the prompt size' do
      tokens = RubyLLM::Tokens.new(input: 1_000, output: 1_000_000, cached: 90_000, cache_creation: 9_001)
      cost = described_class.new(tokens:, model:)

      expect(tokens.prompt).to eq(100_001)
      expect(cost.output).to be_within(1e-12).of(2.50)
      expect(cost.cache_read).to be_within(1e-12).of(90_000 * 0.05 / 1_000_000)
      expect(cost.cache_write).to be_within(1e-12).of(9_001 * 0.625 / 1_000_000)
    end

    it 'keeps the base prices for a prompt at the threshold' do
      tokens = RubyLLM::Tokens.new(input: 100_000, output: 1_000_000)

      expect(described_class.new(tokens:, model:).output).to be_within(1e-12).of(0.50)
    end

    it 'exposes the prices it applied' do
      tokens = RubyLLM::Tokens.new(input: 150_000, output: 10)
      prices = described_class.new(tokens:, model:).text_pricing

      expect([prices.input, prices.output, prices.cache_read_input]).to eq([0.50, 2.50, 0.05])
    end
  end
end
