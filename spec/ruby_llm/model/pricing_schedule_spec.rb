# frozen_string_literal: true

require 'spec_helper'

# Some providers announce a price that changes on a known future date. Recording
# only the current number guarantees the registry is wrong once the date passes.
RSpec.describe RubyLLM::Model::PricingSchedule do
  let(:scheduled_pricing) do
    RubyLLM::Model::Pricing.new(
      text_tokens: {
        standard: {
          schedule: [
            {
              effective_until: '2027-01-01',
              input_per_million: 0.75,
              output_per_million: 3.75,
              cache_read_input_per_million: 0.075
            },
            {
              effective_from: '2027-01-01',
              input_per_million: 1.50,
              output_per_million: 7.50,
              cache_read_input_per_million: 0.15
            }
          ]
        }
      }
    )
  end

  let(:flat_pricing) do
    RubyLLM::Model::Pricing.new(text_tokens: { standard: { input_per_million: 2.0, output_per_million: 6.0 } })
  end

  describe 'resolving the price in effect' do
    it 'answers with the price in effect at a given moment' do
      before_change = scheduled_pricing.at(Time.utc(2026, 12, 31, 23, 59, 59)).text_tokens
      after_change = scheduled_pricing.at(Time.utc(2027, 1, 1)).text_tokens

      expect(before_change.input).to eq(0.75)
      expect(before_change.output).to eq(3.75)
      expect(after_change.input).to eq(1.50)
      expect(after_change.output).to eq(7.50)
    end

    it 'treats effective_until as exclusive and effective_from as inclusive' do
      expect(scheduled_pricing.at(Time.utc(2026, 12, 31)).text_tokens.input).to eq(0.75)
      expect(scheduled_pricing.at(Time.utc(2027, 1, 1)).text_tokens.input).to eq(1.50)
    end

    it 'resolves cache prices on the same schedule' do
      expect(scheduled_pricing.at(Time.utc(2026, 6, 1)).text_tokens.cache_read_input).to eq(0.075)
      expect(scheduled_pricing.at(Time.utc(2027, 6, 1)).text_tokens.cache_read_input).to eq(0.15)
    end

    it 'reports a schedule as scheduled and a flat price as not' do
      expect(scheduled_pricing.scheduled?).to be(true)
      expect(flat_pricing.scheduled?).to be(false)
    end

    it 'leaves flat pricing unaffected by the time asked about' do
      expect(flat_pricing.at(Time.utc(2030, 1, 1)).text_tokens.input).to eq(2.0)
    end

    it 'survives a round trip through the registry representation' do
      round_tripped = RubyLLM::Model::Pricing.new(scheduled_pricing.to_h)

      expect(round_tripped.at(Time.utc(2026, 6, 1)).text_tokens.input).to eq(0.75)
      expect(round_tripped.at(Time.utc(2027, 6, 1)).text_tokens.input).to eq(1.50)
    end
  end

  describe RubyLLM::Cost do
    let(:model) do
      RubyLLM::Model::Info.new(
        id: 'scheduled-model',
        name: 'Scheduled Model',
        provider: 'gemini',
        pricing: scheduled_pricing.to_h
      )
    end

    let(:tokens) { RubyLLM::Tokens.new(input: 1_000_000, output: 1_000_000) }

    it 'prices a call at the moment it was made' do
      promo = described_class.new(tokens:, model:, at: Time.utc(2026, 6, 1))
      standard = described_class.new(tokens:, model:, at: Time.utc(2027, 6, 1))

      expect(promo.total).to be_within(1e-9).of(0.75 + 3.75)
      expect(standard.total).to be_within(1e-9).of(1.50 + 7.50)
    end

    it 'defaults to the price in effect now' do
      expected = model.pricing.text_tokens.input + model.pricing.text_tokens.output

      expect(described_class.new(tokens:, model:).total).to be_within(1e-9).of(expected)
    end
  end

  describe 'degenerate input' do
    it 'ignores entries that carry no prices' do
      pricing = RubyLLM::Model::Pricing.new(
        text_tokens: { standard: { schedule: [{ effective_from: '2027-01-01' }] } }
      )

      expect(pricing.text_tokens.input).to be_nil
    end

    it 'falls back to an undated entry when no dated window matches' do
      pricing = RubyLLM::Model::Pricing.new(
        text_tokens: {
          standard: {
            schedule: [
              { input_per_million: 5.0 },
              { effective_from: '2030-01-01', input_per_million: 9.0 }
            ]
          }
        }
      )

      expect(pricing.at(Time.utc(2026, 1, 1)).text_tokens.input).to eq(5.0)
      expect(pricing.at(Time.utc(2031, 1, 1)).text_tokens.input).to eq(9.0)
    end

    it 'keeps a scheduled price of zero distinct from an unknown one' do
      pricing = RubyLLM::Model::Pricing.new(
        text_tokens: { standard: { schedule: [{ effective_from: '2020-01-01', input_per_million: 0.0 }] } }
      )

      expect(pricing.text_tokens.input).to eq(0.0)
      expect(pricing.text_tokens.output).to be_nil
    end
  end
end
